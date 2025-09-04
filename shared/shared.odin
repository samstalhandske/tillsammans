package shared

import "core:net"

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