package sdl_gpu

import goose "../.."
import "core:testing"
import sdl "vendor:sdl3"

@(test)
goose_sdl_gpu_maps_core_descriptors :: proc(t: ^testing.T) {
	testing.expect(t, shader_format(.Metal_Source) == sdl.GPUShaderFormat{.MSL})
	testing.expect(t, shader_format(.Spirv) == sdl.GPUShaderFormat{.SPIRV})
	testing.expect_value(t, vertex_format(.Float3), sdl.GPUVertexElementFormat.FLOAT3)
	testing.expect_value(t, vertex_format(.Uint4), sdl.GPUVertexElementFormat.UINT4)
	testing.expect_value(t, vertex_format(.Float16x2), sdl.GPUVertexElementFormat.HALF2)
	testing.expect_value(t, vertex_format(.Uint16x4), sdl.GPUVertexElementFormat.USHORT4)
	testing.expect_value(t, vertex_format(.Uint8x4), sdl.GPUVertexElementFormat.UBYTE4)
	testing.expect_value(t, vertex_format(.Unorm8x4), sdl.GPUVertexElementFormat.UBYTE4_NORM)

	attributes := [2]goose.Vertex_Attribute {
		{location = 0, format = .Float3, offset = 0},
		{location = 1, format = .Float2, offset = 12},
	}
	converted := convert_vertex_attributes(attributes[:])
	defer delete(converted)
	testing.expect_value(t, converted[0].format, sdl.GPUVertexElementFormat.FLOAT3)
	testing.expect_value(t, converted[1].format, sdl.GPUVertexElementFormat.FLOAT2)
	testing.expect_value(t, converted[1].offset, u32(12))
}
