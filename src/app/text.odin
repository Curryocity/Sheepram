package app

import "core:strings"

buffer_string :: proc(buffer: []byte) -> string {
	end := 0
	for end < len(buffer) && buffer[end] != 0 do end += 1
	return string(buffer[:end])
}

buffer_clear :: proc(buffer: []byte) {
	for &value in buffer do value = 0
}

buffer_set :: proc(buffer: []byte, text: string) {
	if len(buffer) == 0 do return
	buffer_clear(buffer)
	count := min(len(buffer)-1, len(text))
	copy(buffer[:count], transmute([]byte)text[:count])
}

buffer_trimmed :: proc(buffer: []byte) -> string {
	return strings.trim_space(buffer_string(buffer))
}

