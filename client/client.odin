// tillsammans - MIT License
// Copyright (c) 2025 Sam Stålhandske

package client

import "core:fmt"
import "core:net"
import "core:os"
import "core:sync"
import "core:thread"
import "core:container/queue"

import sh "../shared"

SEND_BUFFER_SIZE :: 1024

Client :: struct {
	endpoint: net.Endpoint,
	socket: net.Any_Socket,

	connected: bool,
	should_stop: bool,

	mutex: sync.Atomic_Mutex,
	
	send_queue: queue.Queue([]u8),

	receive_thread, send_thread: ^thread.Thread,

	on_receive_bytes_from_server: proc([]u8),
}

Create_Client_Result :: enum {
	OK,
	Failed_To_Get_Endpoint,
	Failed_To_Connect,
}

create_client :: proc(ip: string, port: u16, on_receive_bytes_from_server: proc([]u8),) -> (^Client, Create_Client_Result) {
	endpoint, get_endpoint_result := sh.try_get_endpoint(ip, port)
	if get_endpoint_result != .OK {
		fmt.eprintfln("Error! %v.", get_endpoint_result)
		return nil, .Failed_To_Get_Endpoint
	}

	
	assert(on_receive_bytes_from_server != nil)
	
	client := new(Client)
	client^ = {
		endpoint = endpoint,
		on_receive_bytes_from_server = on_receive_bytes_from_server,
	}
	
	queue.init(&client.send_queue)
	
	return client, .OK
}

Start_Client_Result :: enum {
	OK,
	Failed_To_Dial,
}

start_client :: proc(client: ^Client) -> Start_Client_Result {
	assert(client != nil)
	assert(!client.connected)
	assert(client.endpoint != {})

	sock, err := net.dial_tcp_from_endpoint(client.endpoint)
	if err != nil {
		return .Failed_To_Dial
	}

	client.socket = sock
	
	client.connected = true
	fmt.printfln("Started client")

	{ // Set up threads.
		assert(client.receive_thread == nil)
		client.receive_thread = thread.create_and_start_with_poly_data(client, proc(client: ^Client) {
			// fmt.printfln("Receive-thread active.")

			buffer: [256]u8
				
			for client_alive(client) {
				bytes_received, err := net.recv_tcp(client.socket.(net.TCP_Socket), buffer[:])
				if err != nil {
					if err == .Connection_Closed {
						client.should_stop = true
						break
					}
					fmt.printfln("Failed to receive data, error: %v", err)
					break
				}

				if bytes_received == 0 {
					client.should_stop = true
					break
				}

				received := buffer[:bytes_received]
				assert(client.on_receive_bytes_from_server != nil)
				client.on_receive_bytes_from_server(received)
			}
		})

		assert(client.send_thread == nil)
		client.send_thread = thread.create_and_start_with_poly_data(client, proc(client: ^Client) {
			// fmt.printfln("Send-thread active.")

			for client_alive(client) {
				sync.atomic_mutex_lock(&client.mutex)
				defer sync.atomic_mutex_unlock(&client.mutex)

				for queue.len(client.send_queue) > 0 {
					data, ok := queue.pop_back_safe(&client.send_queue)
					if !ok {
						break
					}

					bytes_sent, err := net.send_tcp(client.socket.(net.TCP_Socket), data[:])
					if err != nil {
						if err == .Connection_Closed {
							client.should_stop = true
							break
						}
						fmt.printfln("Failed to send data, error: %v", err)
						break
					}
	
					sent := data[:bytes_sent]
					// fmt.printfln("Client sent %d bytes: %s", len(sent), string(sent))
				}
			}
		})
	}

	return .OK
}

stop_client :: proc(client: ^Client) {
	assert(client != nil)
	assert(client.connected)
	assert(client.socket != {})

	client.connected = false

	thread.destroy(client.send_thread)
	thread.destroy(client.receive_thread)
	client.send_thread = nil
	client.receive_thread = nil

	queue.clear(&client.send_queue)

	net.close(client.socket)
	client.socket = {}

	fmt.printfln("Stopped client")
}

destroy_client :: proc(client: ^Client) {
	queue.destroy(&client.send_queue)
	free(client)
	client^ = {}
}

client_alive :: proc(client: ^Client) -> bool {
	return client.connected && !client.should_stop
}

client_send :: proc(client: ^Client, data: []u8) -> bool {
	assert(client != nil)
	assert(client.connected)

	sync.atomic_mutex_lock(&client.mutex)
	defer sync.atomic_mutex_unlock(&client.mutex)

	queue.push_front(&client.send_queue, data)
	
	return true
}