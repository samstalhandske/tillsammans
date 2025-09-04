// tillsammans - MIT License
// Copyright (c) 2025 Sam Stålhandske

package server

import "core:container/avl"
import "core:log"
import "core:fmt"
import "core:net"
import "core:thread"
import "core:time"
import "core:strings"
import "core:strconv"

// TODO: SS - Add timestamp to server.

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

	// Callbacks.
	server_created_callback, server_started_callback, server_stopped_callback: proc(^Server(T)),
	server_received_bytes_callback: proc(^Server(T), Connection_ID, []u8),
	server_connection_joined: proc(^Server(T), Connection_ID),
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

	data: T, // NOTE: SS - Could add 'using' here but I think it's better to be explicit here.

	commands: map[string]proc(server: ^Server(T), args: []string) -> Command_Result,

	max_connections: u32,
	next_connection_id: Connection_ID,
	connection_map: map[Connection_ID]Connection,

	connection_ids_to_disconnect: [dynamic]Connection_ID,

	// Callbacks.
	start_callback, stop_callback: proc(^Server(T)),
	on_received_bytes_callback: proc(^Server(T), Connection_ID, []u8),
	tick_callback: proc(^Server(T), Tick),
	on_connection_joined: proc(^Server(T), Connection_ID),

	// Threads.
	listen_thread, message_thread, tick_thread: ^thread.Thread,
}

server_alive :: proc(server: $T/^Server) -> bool {
	return server.running && !server.should_stop
}

Create_Server_Result :: enum {
	OK,
	Max_Connections_Needs_To_Be_Bigger_Than_Zero,
	Failed_To_Get_Endpoint,
	Unimplemented_Callback_Received_Bytes,
	Unimplemented_Callback_Tick,
	Invalid_Tickrate,
}

create_server :: proc(spec: Specification($T)) -> (^Server(T), Create_Server_Result) { // TODO: SS - Move some stuff out of the specification-struct and add them as normal parameters.
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

	endpoint, get_endpoint_result := try_get_endpoint(spec.ip, spec.port)
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
		name             = strings.clone(server_name),
		protocol         = spec.protocol,
		endpoint         = endpoint,

		tickrate		 = spec.tickrate,
		tick_mode		 = spec.tick_mode,

		data             = T {},

		commands         = spec.commands,

		max_connections  = spec.max_connections,

		start_callback   			= spec.server_started_callback,
		stop_callback    			= spec.server_stopped_callback,
		on_received_bytes_callback 	= spec.server_received_bytes_callback,
		on_connection_joined 		= spec.server_connection_joined,
		tick_callback 				= spec.server_tick_callback,
	}

	assert(server.on_received_bytes_callback != nil)
	assert(server.tick_callback != nil)

	server.connection_map = make(map[Connection_ID]Connection, server.max_connections)
	server.connection_ids_to_disconnect = make([dynamic]Connection_ID, 0, server.max_connections)
	
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
	assert(server != nil)
	assert(!server.running)
	
	server_log(server, "Starting server ...")
	
	socket, socket_err := net.listen_tcp(server.endpoint)
	if socket_err != nil {
		server_log_error(server, fmt.tprintf("%v.", socket_err))
		return .Failed_To_Listen
	}

	server.socket = socket

	set_blocking_err := net.set_blocking(server.socket, false)
	if set_blocking_err != nil {
		server_log_error(server, fmt.tprintf("Failed to set socket to non-blocking, error: %v.", set_blocking_err))
		return .Failed_To_Set_Non_Blocking
	}

	server.running = true

	if server.start_callback != nil {
		server.start_callback(server)
	}

	server_log(server, "Started server.")

	{ // Set up threads.
		// TODO: SS - Decide if we should only 'create' them in create_server and start them here, or if this is good enough.

		assert(server.listen_thread == nil)
		server.listen_thread = thread.create_and_start_with_poly_data(server, proc(server: T) {
			server_log(server, "Listen-thread active.") 
			
			for server_alive(server) {
				#partial switch server.protocol {
					case .TCP: {
						client_socket, _, accept_err := net.accept_tcp(server.socket.(net.TCP_Socket))
						if accept_err != nil {
							if accept_err == .Would_Block {
								continue
							}

							server_log_error(server, fmt.tprintf("Failed to accept new connection, error: %v.", accept_err))
							continue
						}

						connections_count := u32(len(server.connection_map))
						if connections_count >= server.max_connections {
							server_log(server, fmt.tprintf("Failed to accept new connection, server is full (%v/%v).", connections_count, server.max_connections))

							sorry_msg := "Server is full, sorry! :(\n."
							send_sorry_result := send_bytes_to_socket(client_socket, transmute([]u8)sorry_msg)
							assert(send_sorry_result == .OK)
							
							net.close(client_socket)
							
							continue
						}

						// TODO: SS - Ask the user-program whether we should accept or decline this client.

						server_log(server, fmt.tprintf("Accepted client, socket: %v.", client_socket))
						net.set_blocking(client_socket, should_block = false)

						connection_id := server.next_connection_id
						defer server.next_connection_id += 1
						assert(connection_id not_in server.connection_map)
						server.connection_map[connection_id] = Connection {
							socket = client_socket,
						}

						if server.on_connection_joined != nil {
							server.on_connection_joined(server, connection_id)
						}
					}
					case: {
						assert(false)
					}
				}
				
			}
		})

		assert(server.message_thread == nil)
		server.message_thread = thread.create_and_start_with_poly_data(server, proc(server: T) {
			server_log(server, "Message-thread active.") 
			
			for server_alive(server) {
				buffer: [MAX_RECV_SIZE]u8
		
				for connection_id, connection in server.connection_map {
					if connection.disconnect_reason != nil {
						// Skip connections that are leaving.
						continue
					}
					
					bytes_received := 0
					#partial switch server.protocol {
						case .TCP: {
							b, recv_err := net.recv_tcp(connection.socket.(net.TCP_Socket), buffer[:])
							if recv_err != nil {
								if recv_err == .Would_Block {
									// No data received.
								}
								else {
									server_log_error(server, fmt.tprintf("Failed to receive data, error: %v", recv_err))
								}
								continue
							}

							bytes_received = b
						}
						case: {
							assert(false)
						}
					}

					
					received := buffer[:bytes_received]
					if len(received) == 0 {
						// kick_client(server, &client, .Sent_No_Data)
						server_log_error(
							server,
							fmt.tprintf(
								"Received 0 bytes from connection id %v (socket: %v), kick.",
								connection_id, connection.socket,
							)
						)

						disconnect_connection(server, connection_id, Disconnect_Self {})
						continue
					}
						
					server_log(server, fmt.tprintf("Received %v bytes.", len(received)))
					server.on_received_bytes_callback(server, connection_id, received)
				}
			}
		})

		assert(server.tick_thread == nil)
		server.tick_thread = thread.create_and_start_with_poly_data(server, proc(server: T) {
			server_log(server, "Tick-thread active.")

			current_tick: Tick
			tick_interval := 1000 / f64(Tick(server.tickrate)) // ms per tick.

			should_check_if_proceed :: proc(server: $T/^Server) -> bool {
				switch server.tick_mode {
					case .Always: {}
					case .Only_When_Has_Connections: {
						if len(server.connection_map) == 0 {
							return false
						}
					}
				}

				return true
			}
			proceed_to_next_tick :: proc(server: $T/^Server, current_tick: ^Tick) {
				server.tick_callback(server, current_tick^)
				current_tick^ += 1
			}

			last_tick_time := time.tick_now()

			if should_check_if_proceed(server) {
				proceed_to_next_tick(server, &current_tick)
			}

			for server_alive(server) {
				{ // Disconnect connections that are on their way out.
					ids_to_kick: [max(u8)]Connection_ID
					counter := 0
					for c_id, connection in &server.connection_map {
						if connection.disconnect_reason != nil {
							ids_to_kick[counter] = c_id
							counter += 1
						}
					}
					for id in ids_to_kick[:counter] {
						conn := &server.connection_map[id]

						bye_msg := ""
						switch &r in conn.disconnect_reason {
							case Disconnect_Self: {
								bye_msg = "Disconnected.\n"
							}
							case Disconnect_Kick: {
								switch r.reason {
									case .Idle: {
										bye_msg = "Kicked! Idle too long.\n"
									}
									case .Cheating: {
										bye_msg = "Kicked! Cheating.\n"
									}
								}
							}
						}

						send_bye_result := send_bytes_to_socket(conn.socket, transmute([]u8)bye_msg)
						assert(send_bye_result == .OK)

						// TODO: SS - If we want the connection to get the 'bye' message we might have to 'sleep' for a bit before closing the socket.
						
						net.close(conn.socket)
						delete_key(&server.connection_map, id)
					}
				}
				
				if !should_check_if_proceed(server) {
					time.sleep(100)
					continue
				}
				
				now := time.tick_now()
				elapsed := time.tick_diff(last_tick_time, now)

				if time.duration_milliseconds(elapsed) >= tick_interval {
					proceed_to_next_tick(server, &current_tick)
					last_tick_time = time.tick_now()
				} else {
					time.sleep(1)
				}
			}
		})
	}
	
	return .OK
}

stop_server :: proc(server: $T/^Server) {
	assert(server != nil)
	assert(server.running)

	server_log(server, "Stopping server ...")

	switch server.protocol {
		case .TCP: net.close(server.socket.(net.TCP_Socket))
		case .UDP: net.close(server.socket.(net.UDP_Socket))
	}

	server.running = false

	if server.stop_callback != nil {
		server.stop_callback(server)
	}

	for c_id, conn in server.connection_map {
		switch server.protocol {
			case .TCP: net.close(conn.socket.(net.TCP_Socket))
			case .UDP: net.close(conn.socket.(net.UDP_Socket))
		}
	}
	clear(&server.connection_map)

	thread.destroy(server.listen_thread)
	thread.destroy(server.message_thread)
	thread.destroy(server.tick_thread)
	server.listen_thread  = nil
	server.message_thread = nil
	server.tick_thread = nil

	server_log(server, "Stopped server.")
}

destroy_server :: proc(server: $T/^Server) {
	assert(server != nil)
	assert(!server.running)

	delete(server.name)
	delete(server.connection_map)

	server^ = {}
}

send_bytes_to_connection_id :: proc(server: $T/^Server, id: Connection_ID, data: []u8) {
	conn, ok := &server.connection_map[id]
	if !ok {
		server_log_error(server, fmt.tprintf("Failed to send bytes to connection id %v, not found in map.", id))
		return
	}

	
	if len(data) == 0 {
		server_log_error(server, fmt.tprintf("Failed to send bytes to connection id %v, length of data is 0.", id))
		return
	}
	
	socket := conn.socket
	send_result := send_bytes_to_socket(conn.socket, data)
	switch send_result {
		case .OK: {
			server_log(server, fmt.tprintf("Sent %v bytes to connection id %v (socket: %v).", len(data), id, socket))
		}
		case .TCP_Error: {
			server_log_error(server, fmt.tprintf("Failed to send %v bytes to socket %v from server.", len(data), socket))
		}
	}
}

Send_Bytes_To_Socket_Result :: enum {
	OK,
	TCP_Error,
}
send_bytes_to_socket :: proc(socket: net.Any_Socket, data: []u8) -> Send_Bytes_To_Socket_Result {
	#partial switch &s in socket {
		case net.TCP_Socket: {
			bytes_sent, err_send := net.send_tcp(s, data)
			if err_send != nil {
				fmt.eprintfln("Send error! %v", err_send)
				return .TCP_Error
			}
		}
		case: {
			assert(false)
		}
	}

	return .OK	
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

	// switch cmd {
	//     case "kick": {
	//         if len(server.connected_clients) == 0 {
	//             fmt.eprintln("No one to kick.")
	//             break
	//         }

	//         if len(split_result) != 2 {
	//             fmt.eprintfln("Expected 2 arguments, got %v.", len(split_result))
	//             fmt.eprintfln("kick <socket>")
	//             break
	//         }

	//         id_to_kick, ok := strconv.parse_i64(split_result[1])
	//         if !ok {
	//             fmt.eprintfln("Failed to kick because we failed to parse argument '%v' as an i64.", split_result[1])
	//             break
	//         }

	//         socket_to_kick := net.TCP_Socket(id_to_kick)

	//         if socket_to_kick not_in server.connected_clients {
	//             fmt.eprintfln("Socket '%v' not found in list of clients.", socket_to_kick)
	//             break
	//         }

	//         kick_client(&server, socket_to_kick, .Admin_Command)
	//     }
	//     case "send": {
	//         if len(server.connected_clients) == 0 {
	//             fmt.eprintln("No one to send string to.")
	//             break
	//         }

	//         if len(split_result) < 3 {
	//             fmt.eprintfln("Expected 3+ arguments, got %v.", len(split_result))
	//             fmt.eprintfln("send <socket> <string>")
	//             break
	//         }

	//         socket_i64, ok := strconv.parse_i64(split_result[1])
	//         if !ok {
	//             fmt.eprintfln("Failed to parse argument '%v' as an i64.", split_result[1])
	//             break
	//         }

	//         socket_to_send_data_to := net.TCP_Socket(socket_i64)

	//         if socket_to_send_data_to not_in server.connected_clients {
	//             fmt.eprintfln("Socket '%v' not found in list of clients.", socket_to_send_data_to)
	//             break
	//         }

	//         if !server_send(&server, socket_to_send_data_to, split_result[2:]) {
	//             // ..
	//         }
	//     }
	//     case: {
	//         fmt.eprintfln("Unknown command '%v'.", split_result[0])
	//     }
	// }
}

@(private="file") Try_Get_Endpoint_Result :: enum {
	OK,
	Failed_To_Parse_IP_Address,
}

@(private="file") try_get_endpoint :: proc(ip_str: string, port: u16) -> (net.Endpoint, Try_Get_Endpoint_Result) {
	ip_addr, parse_ip_ok := net.parse_ip4_address(ip_str)
	if !parse_ip_ok {
		return {}, .Failed_To_Parse_IP_Address
	}

	return net.Endpoint {
		address = ip_addr,
		port = int(port),
	}, .OK
}

get_server_name_with_ip_port :: proc(server: $T/^Server) -> string {
	assert(server != nil)
	return fmt.tprintf("'%v' (%v)", server.name, net.endpoint_to_string(server.endpoint))
}

server_log :: proc(server: $T/^Server, text: string) {
	fmt.printfln("%v %v", fmt.tprintf("TILLSAMMANS %v >>", get_server_name_with_ip_port(server)), text)
}

server_log_error :: proc(server: $T/^Server, text: string, loc := #caller_location) {
	fmt.printfln("%v ERROR! %v ~ %v", fmt.tprintf("TILLSAMMANS %v >>", get_server_name_with_ip_port(server)), loc, text)
}



// Two_Way_Map :: struct($A, $B: typeid) {
// 	a_to_b: map[A]B,
// 	b_to_a: map[B]A,
// }

// add_to_two_way_map :: proc(m: ^Two_Way_Map($A, $B), a: A, b: B) {
// 	assert(a not_in m.a_to_b)
// 	assert(b not_in m.b_to_a)

// 	m.a_to_b[a] = b
// 	m.b_to_a[b] = a
// }

// get_from_two_way_map :: proc {
// 	get_a_from_two_way_map,
// 	get_b_from_two_way_map,   
// }
// get_a_from_two_way_map :: proc(m: ^Two_Way_Map($A, $B), b: B) -> (A, bool) {
// 	return m.b_to_a[b]
// }
// get_b_from_two_way_map :: proc(m: ^Two_Way_Map($A, $B), a: A) -> (B, bool) {
// 	return m.a_to_b[a]
// }

// remove_from_two_way_map :: proc {
// 	remove_a_from_two_way_map,
// 	remove_b_from_two_way_map,
// }
// remove_a_from_two_way_map :: proc(m: ^Two_Way_Map($A, $B), a: A) {
// 	assert(a in m.a_to_b)

// 	b := m.a_to_b[a]
	
// 	delete_key(&m.a_to_b, a)
// 	delete_key(&m.b_to_a, b)
// }
// remove_b_from_two_way_map :: proc(m: ^Two_Way_Map($A, $B), b: B) {
// 	assert(b in m.b_to_a)

// 	a := m.b_to_a[b]
	
// 	delete_key(&m.b_to_a, b)
// 	delete_key(&m.a_to_b, a)
// }

// clear_two_way_map :: proc(m: ^Two_Way_Map($A, $B)) {
// 	clear(&m.a_to_b)
// 	clear(&m.b_to_a)
// }

// make_two_way_map :: proc(m: ^Two_Way_Map($A, $B), cap: u32) {
// 	m.a_to_b = make(map[A]B, cap)
// 	m.b_to_a = make(map[B]A, cap)
// }

// destroy_two_way_map :: proc(m: ^Two_Way_Map($A, $B)) {
// 	delete(m.a_to_b)
// 	delete(m.b_to_a)
// }

Disconnect_Reason :: union {
	Disconnect_Self,
	Disconnect_Kick,
}

Disconnect_Self :: struct {
}

Kick_Reason :: enum {
	Idle,
	Cheating,
	// ..
}
Disconnect_Kick :: struct {
	reason: Kick_Reason,
}

disconnect_connection :: proc(server: $T/^Server, id: Connection_ID, reason: Disconnect_Reason) {	
	connection, ok := &server.connection_map[id]
	assert(ok)
	if connection.disconnect_reason != nil {
		server_log_error(server, fmt.tprintf("Failed to disconnect connection id %v cause it's already on it's way out. (%v)", id, connection.disconnect_reason))
		return
	}

	connection.disconnect_reason = reason
}