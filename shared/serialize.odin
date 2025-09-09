package shared

import "core:bytes"

serialize_tcp_message :: proc(buf: ^bytes.Buffer, v: TCP_Message) {
    serialize_u32_le(buf, v.length)
    for i in 0..<v.length {
        serialize_u8(buf, v.data[i])
    }
}

serialize_u8 :: proc(buf: ^bytes.Buffer, v: u8) {
	err := bytes.buffer_write_byte(buf, v)
	assert(err == .None)
}

serialize_u32_le :: proc(buf: ^bytes.Buffer, v: u32) {
	serialize_u8(buf, u8(v >> 0))
	serialize_u8(buf, u8(v >> 8))
	serialize_u8(buf, u8(v >> 16))
	serialize_u8(buf, u8(v >> 24))
}

serialize_f32_le :: proc(buf: ^bytes.Buffer, v: f32) {
	bs := transmute([4]u8)v
	for i in 0..<4 {
		serialize_u8(buf, bs[i])
	}
}