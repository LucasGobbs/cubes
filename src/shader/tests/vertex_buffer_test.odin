package shader_tests

import "core:testing"
import sdl "vendor:sdl3"

Vertex_Buffer_Test_Vertex :: struct {
	position: [3]f32,
	normal:   [3]f32,
	uv:       [2]f32,
	joints:   [4]u32,
}

@(test)
shader_vertex_attributes_are_reflected_independently :: proc(t: ^testing.T) {
	attributes := vertex_buffers_vertex_attributes(Vertex_Buffer_Test_Vertex)
	testing.expect_value(t, len(attributes), 4)
	testing.expect_value(t, attributes[0].location, u32(0))
	testing.expect_value(t, attributes[0].format, sdl.GPUVertexElementFormat.FLOAT3)
	testing.expect_value(
		t,
		attributes[0].offset,
		u32(offset_of(Vertex_Buffer_Test_Vertex, position)),
	)
	testing.expect_value(t, attributes[1].format, sdl.GPUVertexElementFormat.FLOAT3)
	testing.expect_value(
		t,
		attributes[1].offset,
		u32(offset_of(Vertex_Buffer_Test_Vertex, normal)),
	)
	testing.expect_value(t, attributes[2].format, sdl.GPUVertexElementFormat.FLOAT2)
	testing.expect_value(t, attributes[2].offset, u32(offset_of(Vertex_Buffer_Test_Vertex, uv)))
	testing.expect_value(t, attributes[3].format, sdl.GPUVertexElementFormat.UINT4)
	testing.expect_value(
		t,
		attributes[3].offset,
		u32(offset_of(Vertex_Buffer_Test_Vertex, joints)),
	)
}
