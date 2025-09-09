package shared

import "core:net"
import "core:bytes"

Try_Get_Endpoint_Result :: enum {
	OK,
	Failed_To_Parse_IP_Address,
}

try_get_endpoint :: proc(ip_str: string, port: u16) -> (net.Endpoint, Try_Get_Endpoint_Result) {
	ip_addr, parse_ip_ok := net.parse_ip4_address(ip_str)
	if !parse_ip_ok {
		return {}, .Failed_To_Parse_IP_Address
	}

	return net.Endpoint {
		address = ip_addr,
		port = int(port),
	}, .OK
}

TCP_Message :: struct {
	length: u32,
	data: []u8,
}

to_tcp_message :: proc(data: []u8) -> TCP_Message {
	message := TCP_Message {
		length = u32(len(data)),
		data = data
	}

	assert(message.length > 0)
	return message
}

from_tcp_message :: proc(r: ^bytes.Reader) -> (bytes_read, bytes_to_read: u32, ok: bool) {
	message_length := deserialize_u32_le(r)

	diff := i32(bytes.reader_length(r)) - i32(message_length)
	if diff >= 0{
		return 4, message_length, true
	}

	return 0, 0, false
}