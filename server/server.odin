// tillsammans - MIT License
// Copyright (c) 2025 Sam Stålhandske

package server

import "core:container/avl"
import "core:bytes"
import "core:fmt"
import "core:net"
import "core:thread"
import "core:time"
import "core:strings"
import "core:sync"

import sh "../shared"

MAX_RECV_SIZE :: 1024

Tick :: distinct u64

Tick_Mode :: enum {
	Always,
	Only_When_Has_Connections,
}

Specification :: struct($T: typeid) {
	name: string,
	protocol: Protocol,
	ip: string,
	port: u16,

	tickrate: u8,
	tick_mode: Tick_Mode,

	max_connections: u32,

	commands: map[string]proc(server: ^Server(T), args: []string) -> Command_Result,

	server_created_callback, server_started_callback, server_stopped_callback: proc(^Server(T)),
	server_received_bytes_callback: proc(^Server(T), Connection_ID, []u8),
	server_connection_joined, server_connection_disconnected: proc(^Server(T), Connection_ID),
	server_tick_callback: proc(^Server(T), Tick),
}

Protocol :: enum {
	TCP,
	UDP,
}

Connection_ID :: distinct u32

Connection :: struct {
	socket: net.Any_Socket,
	disconnect_reason: Disconnect_Reason,
}

Server :: struct($T: typeid) {
	name: string,
	protocol: Protocol,
	endpoint: net.Endpoint,
	socket: net.Any_Socket,

	tickrate: u8,
	tick_mode: Tick_Mode,

	running: bool,
	should_stop: bool,

	mutex: sync.Atomic_Mutex,

	data: T,
	commands: map[string]proc(server: ^Server(T), args: []string) -> Command_Result,

	max_connections: u32,
	next_connection_id: Connection_ID,
	connection_map: map[Connection_ID]Connection,

	incoming_queue: Message_Queue(Incoming_Message),
	outgoing_queue: Message_Queue(Outgoing_Message),
	control_queue_from_tick: Message_Queue(Control_Message),
	events_for_tick_queue: Message_Queue(Server_Event),

	start_callback, stop_callback: proc(^Server(T)),
	on_received_bytes_callback: proc(^Server(T), Connection_ID, []u8),
	tick_callback: proc(^Server(T), Tick),
	on_connection_joined, on_connection_disconnected: proc(^Server(T), Connection_ID),

	listen_thread, tick_thread: ^thread.Thread,
}

Message_Queue :: struct($T: typeid) {
	mutex: sync.Atomic_Mutex,
	items: [dynamic]T,
}

message_queue_push :: proc($T: typeid, q: ^Message_Queue(T), item: T) {
	sync.atomic_mutex_lock(&q.mutex)
	defer sync.atomic_mutex_unlock(&q.mutex)
	append(&q.items, item)
}

message_queue_drain :: proc($T: typeid, q: ^Message_Queue(T), out: ^[dynamic]T) {
	sync.atomic_mutex_lock(&q.mutex)
	defer sync.atomic_mutex_unlock(&q.mutex)
	out^ = q.items
	clear(&q.items)
}

Incoming_Message :: struct {
	connection_id: Connection_ID,
	data: []u8,
}

Outgoing_Message :: struct {
	connection_id: Connection_ID,
	data: []u8,
}

Control_Message :: union {
	Disconnect_Message,
}
Server_Event :: union {
	Join_Message,
	Disconnect_Message,
}
Join_Message :: struct {
	connection_id: Connection_ID,
}
Disconnect_Message :: struct {
	connection_id: Connection_ID,
}

Disconnect_Reason :: union {
	Disconnect_Self,
	Disconnect_Kick,
}

Disconnect_Self :: struct {}

Kick_Reason :: enum {
	Idle,
	Cheating,
	// ..
}
Disconnect_Kick :: struct {
	reason: Kick_Reason,
}

Create_Server_Result :: enum {
	OK,
	Max_Connections_Needs_To_Be_Bigger_Than_Zero,
	Failed_To_Get_Endpoint,
	Unimplemented_Callback_Received_Bytes,
	Unimplemented_Callback_Tick,
	Invalid_Tickrate,
}

create_server :: proc(spec: Specification($T)) -> (^Server(T), Create_Server_Result) {
	assert(spec.protocol == .TCP, "Only TCP allowed at the moment.")

	if spec.max_connections == 0 {
		return nil, .Max_Connections_Needs_To_Be_Bigger_Than_Zero
	}
	if spec.server_received_bytes_callback == nil {
		return nil, .Unimplemented_Callback_Received_Bytes
	}
	if spec.server_tick_callback == nil {
		return nil, .Unimplemented_Callback_Tick
	}
	if spec.tickrate == 0 {
		return nil, .Invalid_Tickrate
	}

	endpoint, get_endpoint_result := sh.try_get_endpoint(spec.ip, spec.port)
	if get_endpoint_result != .OK {
		fmt.eprintfln("Error! %v.", get_endpoint_result)
		return nil, .Failed_To_Get_Endpoint
	}

	server_name := "unnamed_server"
	if len(spec.name) > 0 {
		server_name = spec.name
	}

	server := new(Server(T))
	server^ = {
		name = strings.clone(server_name),
		protocol = spec.protocol,
		endpoint = endpoint,
		tickrate = spec.tickrate,
		tick_mode = spec.tick_mode,
		data = T{},
		commands = spec.commands,
		max_connections = spec.max_connections,
		start_callback = spec.server_started_callback,
		stop_callback = spec.server_stopped_callback,
		on_received_bytes_callback = spec.server_received_bytes_callback,
		on_connection_joined = spec.server_connection_joined,
		on_connection_disconnected = spec.server_connection_disconnected,
		tick_callback = spec.server_tick_callback,
	}

	server.connection_map = make(map[Connection_ID]Connection, server.max_connections)

	if spec.server_created_callback != nil {
		spec.server_created_callback(server)
	}

	return server, .OK
}

Start_Server_Result :: enum {
	OK,
	Failed_To_Listen,
	Failed_To_Set_Non_Blocking,
}

start_server :: proc(server: $T/^Server) -> Start_Server_Result {
	socket, err := net.listen_tcp(server.endpoint)
	if err != nil {
		server_log_error(server, fmt.tprintf("Failed to listen: %v", err))
		return .Failed_To_Listen
	}
	server.socket = socket
	set_block_err := net.set_blocking(socket, false)
	if set_block_err != .None {
		return .Failed_To_Set_Non_Blocking
	}
	server.running = true

	if server.start_callback != nil { server.start_callback(server) }

	server_log(server, "Server started.")

	// Start threads.
	start_io_thread(server)
	start_tick_thread(server)

	return .OK
}

stop_server :: proc(server: $T/^Server) {
	assert(server != nil)
	server.running = false

	net.close(server.socket)
	for id, conn in server.connection_map {
		net.close(conn.socket)
	}
	clear(&server.connection_map)

	// Stop threads.
	thread.destroy(server.listen_thread)
	thread.destroy(server.tick_thread)
	server.listen_thread = nil
	server.tick_thread = nil

	if server.stop_callback != nil { server.stop_callback(server) }

	server_log(server, "Server stopped.")
}

send_bytes_to_connection :: proc(server: $T/^Server, id: Connection_ID, data: []u8) {
	data_copy := make([]u8, len(data))
	copy(data_copy, data)
	message_queue_push(Outgoing_Message, &server.outgoing_queue, Outgoing_Message{ connection_id = id, data = data_copy })
}

send_bytes_to_all_connections :: proc(server: $T/^Server, data: []u8) {
	for id in server.connection_map {
		send_bytes_to_connection(server, id, data)
	}
}

get_server_name_with_ip_port :: proc(server: $T/^Server) -> string {
	assert(server != nil)
	return fmt.tprintf("'%v' (%v)", server.name, net.endpoint_to_string(server.endpoint))
}

server_log :: proc(server: $T/^Server, text: string) {
	fmt.printfln("[SERVER %v] %v", get_server_name_with_ip_port(server), text)
}

server_log_error :: proc(server: $T/^Server, text: string) {
	fmt.printfln("[SERVER %v] ERROR: %v", get_server_name_with_ip_port(server), text)
}

start_io_thread :: proc(server: $T/^Server) {
	assert(server.listen_thread == nil)

	server.listen_thread = thread.create_and_start_with_poly_data(server, proc(server: T) {
		server_log(server, "IO-thread active.")

		buffer: [MAX_RECV_SIZE]u8

		for server.running {
			client_socket, _, err := net.accept_tcp(server.socket.(net.TCP_Socket))
			if err == nil {
				connections_count := u32(len(server.connection_map))
				if connections_count >= server.max_connections {
					server_log(server, fmt.tprintf("Server full, rejecting client."))
					// TODO: SS - Send 'Server_Full' message.
					net.close(client_socket)
					continue
				}

				connection_id := server.next_connection_id
				defer server.next_connection_id += 1

				sync.atomic_mutex_lock(&server.mutex)
				server.connection_map[connection_id] = Connection {
					socket = client_socket
				}
				sync.atomic_mutex_unlock(&server.mutex)

				message_queue_push(Server_Event, &server.events_for_tick_queue, Join_Message {
					connection_id = connection_id
				})

				server_log(server, fmt.tprintf("Accepted client %v.", connection_id))
				net.set_blocking(client_socket, false)
			}

			for connection_id, conn in server.connection_map {
				if conn.disconnect_reason != nil {
					continue
				}

				n, recv_err := net.recv_tcp(conn.socket.(net.TCP_Socket), buffer[:])
				if recv_err != nil {
					if recv_err == .Would_Block {
						continue
					}
					
					if recv_err == .Connection_Closed || recv_err == .Invalid_Argument {
						message_queue_push(Control_Message, &server.control_queue_from_tick, Disconnect_Message {
							connection_id = connection_id
						})
						continue
					}

					server_log_error(server, fmt.tprintf("Recv error: %v", recv_err))
					continue
				}

				if n == 0 {
					message_queue_push(Control_Message, &server.control_queue_from_tick, Disconnect_Message {
						connection_id = connection_id
					})
					continue
				}

				if n > 0 {
					recv_copy := make([]u8, n)
					copy(recv_copy, buffer[:n])
					message_queue_push(Incoming_Message, &server.incoming_queue, Incoming_Message{connection_id, recv_copy})
				}
			}

			{
				outgoing_msgs: [dynamic]Outgoing_Message
				message_queue_drain(Outgoing_Message, &server.outgoing_queue, &outgoing_msgs)

				buf: bytes.Buffer
				bytes.buffer_init_allocator(&buf, 0, 1024)
				for msg in outgoing_msgs {
					conn, ok := server.connection_map[msg.connection_id]
					assert(ok)
					if len(msg.data) > 0 {
						sh.serialize_tcp_message(&buf, sh.to_tcp_message(msg.data))
						bytes_written, err := net.send_tcp(conn.socket.(net.TCP_Socket), bytes.buffer_to_bytes(&buf))
						assert(err == .None, fmt.tprintf("Got err %v when sending %v bytes to %v.", err, len(msg.data), msg.connection_id))
					}
				}

				bytes.buffer_destroy(&buf)
				
				time.sleep(1)
			}
		}
	})
}

start_tick_thread :: proc(server: $T/^Server) {
	assert(server.tick_thread == nil)

	server.tick_thread = thread.create_and_start_with_poly_data(server, proc(server: T) {
		server_log(server, "Tick-thread active.")

		current_tick: Tick = 0
		tick_interval := 1.0 / f64(server.tickrate)
		last_tick := time.tick_now()

		for server.running {
			tick_now := time.tick_now()
			elapsed := time.duration_seconds(time.tick_diff(last_tick, tick_now))

			switch server.tick_mode {
				case .Always: {}
				case .Only_When_Has_Connections: {
					if len(server.connection_map) == 0 {
						continue
					}
				}
			}

			if elapsed >= tick_interval {
				last_tick = tick_now

				control_msgs: [dynamic]Control_Message
				message_queue_drain(Control_Message, &server.control_queue_from_tick, &control_msgs)
				for msg in control_msgs {
					switch &m in msg {
						case Disconnect_Message: {
							conn, ok := server.connection_map[m.connection_id]
							if ok {
								net.close(conn.socket)

								sync.atomic_mutex_lock(&server.mutex)
								delete_key(&server.connection_map, m.connection_id)
								sync.atomic_mutex_unlock(&server.mutex)

								message_queue_push(Server_Event, &server.events_for_tick_queue, Disconnect_Message {
									connection_id = m.connection_id
								})
							}
						}
					}
				}

				incoming_msgs: [dynamic]Incoming_Message
				message_queue_drain(Incoming_Message, &server.incoming_queue, &incoming_msgs)
				for msg in incoming_msgs {
					server.on_received_bytes_callback(server, msg.connection_id, msg.data)
				}

				events: [dynamic]Server_Event
				message_queue_drain(Server_Event, &server.events_for_tick_queue, &events)
				for event in events {
					switch &e in event {
						case Join_Message: {
							if server.on_connection_joined != nil {
								server.on_connection_joined(server, e.connection_id)
							}
						}
						case Disconnect_Message: {
							if server.on_connection_disconnected != nil {
								server.on_connection_disconnected(server, e.connection_id)
							}
						}
					}
				}

				server.tick_callback(server, current_tick)
				current_tick += 1
			} else {
				time.sleep(1)
			}
		}
	})
}

server_alive :: proc(server: $T/^Server) -> bool {
	return server.running && !server.should_stop
}

Command_Result :: enum {
	OK,
	Not_Enough_Arguments,
	Too_Many_Arguments,
	Unknown,
}

try_run_command :: proc(server: $T/^Server, input: string) -> Command_Result {
	assert(server != nil)

	split_result := strings.split(input, " ")
	defer delete(split_result)

	primary_command := split_result[0]

	cmd, ok := server.commands[primary_command]
	if !ok {
		fmt.eprintfln("%v Unknown command '%v'.", primary_command) 
		return .Unknown
	}

	return cmd(server, split_result[1:])
}

destroy_server :: proc(server: $T/^Server) {
	assert(server != nil)
	assert(!server.running)

	delete(server.name)
	delete(server.connection_map)

	free(server)

	server^ = {}
}