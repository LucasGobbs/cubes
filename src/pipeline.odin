package main
import "core:log"
import sdl "vendor:sdl3"
gfx_basic_pipeline :: proc(gfx: ^Gfx) -> ^sdl.GPUGraphicsPipeline {
	vert_shader := load_shader("../shaders/generated/triangle.vert.msl", gfx.gpu, .VERTEX, 1, 0)
	frag_shader := load_shader("../shaders/generated/triangle.frag.msl", gfx.gpu, .FRAGMENT, 0, 1)

	vertex_attrs := []sdl.GPUVertexAttribute {
		{location = 0, format = .FLOAT3, offset = u32(offset_of(VertexData, position))},
		{location = 1, format = .FLOAT4, offset = u32(offset_of(VertexData, color))},
		{location = 2, format = .FLOAT2, offset = u32(offset_of(VertexData, uv))},
	}

	pipeline := sdl.CreateGPUGraphicsPipeline(
		gfx.gpu,
		{
			vertex_shader = vert_shader,
			fragment_shader = frag_shader,
			primitive_type = .TRIANGLELIST,
			vertex_input_state = {
				num_vertex_buffers = 1,
				vertex_buffer_descriptions = &(sdl.GPUVertexBufferDescription {
						slot = 0,
						pitch = size_of(VertexData),
					}),
				num_vertex_attributes = u32(len(vertex_attrs)),
				vertex_attributes = raw_data(vertex_attrs),
			},
			depth_stencil_state = {
				enable_depth_test = true,
				enable_depth_write = true,
				compare_op = .LESS,
			},
			target_info = {
				num_color_targets = 1,
				color_target_descriptions = &(sdl.GPUColorTargetDescription {
						format = sdl.GetGPUSwapchainTextureFormat(gfx.gpu, gfx.window),
					}),
				has_depth_stencil_target = true,
				depth_stencil_format = .D32_FLOAT,
			},
		},
	)
	sdl.ReleaseGPUShader(gfx.gpu, vert_shader)
	sdl.ReleaseGPUShader(gfx.gpu, frag_shader)

	return pipeline
}
