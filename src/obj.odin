package main
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
ObjData :: struct {
	positions: []Vec3,
	uv:        []Vec2,
	faces:     []ObjFaceIndex,
}

ObjFaceIndex :: struct {
	pos: uint,
	uv:  uint,
}

obj_load :: proc(filename: string) -> ObjData {
	data, err := os.read_entire_file_from_path(filename, context.allocator); assert(err == nil)
	defer delete(data)

	input_string := string(data)
	positions := make([dynamic]Vec3)
	uvs := make([dynamic]Vec2)
	faces := make([dynamic]ObjFaceIndex)
	for line in strings.split_lines_iterator(&input_string) {
		if len(line) == 0 do continue
		log.debug(line)
		switch line[0] {
		case 'v':
			switch line[1] {
			case ' ':
				pos := parse_position(line[2:])
				append(&positions, pos)
			case 't':
				uv := parse_uv(line[2:])
				append(&uvs, uv)
			}
		case 'f':
			indices := parse_face(line[2:])
			append_elems(&faces, indices[0], indices[1], indices[2])
		}

	}
	return {positions = positions[:], uv = uvs[:], faces = faces[:]}
}

obj_destroy :: proc(obj: ^ObjData) {
	delete(obj.positions)
	delete(obj.uv)
	delete(obj.faces)
}

parse_position :: proc(s: string) -> Vec3 {
	s := strings.trim_left_space(s)
	x := extract_separated(&s, ' ')
	y := extract_separated(&s, ' ')
	z := extract_separated(&s, ' ')

	return {parse_f32(strings.trim_space(x)), parse_f32(strings.trim_space(y)), parse_f32(strings.trim_space(z))}
}

parse_uv :: proc(s: string) -> Vec2 {
	s := strings.trim_left_space(s)
	u := extract_separated(&s, ' ')
	v := extract_separated(&s, ' ')

	return {parse_f32(strings.trim_space(u)), parse_f32(strings.trim_space(v))}
}

parse_face :: proc(s: string) -> [3]ObjFaceIndex {
	s := strings.trim_left_space(s)
	return {
		parse_face_index(extract_separated(&s, ' ')),
		parse_face_index(extract_separated(&s, ' ')),
		parse_face_index(extract_separated(&s, ' ')),
	}
}

parse_face_index :: proc(s: string) -> ObjFaceIndex {
	s := s

	return {
		pos = parse_uint(extract_separated(&s, '/')) - 1,
		uv = parse_uint(extract_separated(&s, '/')) - 1,
	}
}

extract_separated :: proc(s: ^string, sep: byte) -> string {
	substr, ok := strings.split_by_byte_iterator(s, sep); assert(ok)
	return substr
}

parse_f32 :: proc(s: string) -> f32 {
	n, ok := strconv.parse_f32(s)
	assert(ok)
	return n
}

parse_uint :: proc(s: string) -> uint {
	n, ok := strconv.parse_uint(s)
	assert(ok)
	return n
}
