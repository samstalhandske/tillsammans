package shared

import "core:bytes"

deserialize_u8 :: proc(r: ^bytes.Reader) -> u8 {
	v, err := bytes.reader_read_byte(r)
	assert(err ==. None)
	return v
}

deserialize_u32_le :: proc(r: ^bytes.Reader) -> u32 {
	assert(bytes.reader_length(r) >= 4)

	a := u32(deserialize_u8(r))
	b := u32(deserialize_u8(r))
	c := u32(deserialize_u8(r))
	d := u32(deserialize_u8(r))

	return a | (b << 8) | (c << 16) | (d << 24)
}

deserialize_f32_le :: proc(r: ^bytes.Reader) -> f32 {
    assert(bytes.reader_length(r) >= 4)
	
    bs: [4]u8
    for i in 0..<4 {
		bs[i] = deserialize_u8(r)
	}
	
    return transmute(f32)bs
}