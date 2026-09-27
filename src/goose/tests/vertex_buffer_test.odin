package goose_tests

import goose ".."
import "core:testing"

Vertex_Buffer_Test_Vertex :: struct {
	position:     [3]f32,
	normal:       [3]f32,
	uv:           [2]f32,
	joints:       [4]u32,
	weights:      [2]f16,
	bone_indices: [4]u16,
	flags:        [4]u8,
}
@(test)
shader_vertex_attributes_are_reflected_independently :: proc(t: ^testing.T) {
	attributes := vertex_buffers_vertex_attributes(Vertex_Buffer_Test_Vertex)
	testing.expect_value(t, len(attributes), 7)
	testing.expect_value(t, attributes[0].location, u32(0))
	testing.expect_value(t, attributes[0].format, goose.Vertex_Format.Float3)
	testing.expect_value(
		t,
		attributes[0].offset,
		u32(offset_of(Vertex_Buffer_Test_Vertex, position)),
	)
	testing.expect_value(t, attributes[1].format, goose.Vertex_Format.Float3)
	testing.expect_value(
		t,
		attributes[1].offset,
		u32(offset_of(Vertex_Buffer_Test_Vertex, normal)),
	)
	testing.expect_value(t, attributes[2].format, goose.Vertex_Format.Float2)
	testing.expect_value(t, attributes[2].offset, u32(offset_of(Vertex_Buffer_Test_Vertex, uv)))
	testing.expect_value(t, attributes[3].format, goose.Vertex_Format.Uint4)
	testing.expect_value(
		t,
		attributes[3].offset,
		u32(offset_of(Vertex_Buffer_Test_Vertex, joints)),
	)
	testing.expect_value(t, attributes[4].format, goose.Vertex_Format.Float16x2)
	testing.expect_value(
		t,
		attributes[4].offset,
		u32(offset_of(Vertex_Buffer_Test_Vertex, weights)),
	)
	testing.expect_value(t, attributes[5].format, goose.Vertex_Format.Uint16x4)
	testing.expect_value(
		t,
		attributes[5].offset,
		u32(offset_of(Vertex_Buffer_Test_Vertex, bone_indices)),
	)
	testing.expect_value(t, attributes[6].format, goose.Vertex_Format.Uint8x4)
	testing.expect_value(t, attributes[6].offset, u32(offset_of(Vertex_Buffer_Test_Vertex, flags)))
}
