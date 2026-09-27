package main
import shader "shader"
import shader_parameters "shader_parameters"
import sdl "vendor:sdl3"

Draw_Parameters :: struct {
	view_projection: matrix[4, 4]f32,
	model_transform: matrix[4, 4]f32,
}

Pipeline_Bind_Draw_Proc :: #type proc(
	user_data: rawptr,
	command_buffer: ^sdl.GPUCommandBuffer,
	parameters: Draw_Parameters,
)

Pipeline :: struct {
	handle:    ^sdl.GPUGraphicsPipeline,
	user_data: rawptr,
	bind_draw: Pipeline_Bind_Draw_Proc,
}

pipeline_bind_draw :: proc(
	pipeline: ^Pipeline,
	command_buffer: ^sdl.GPUCommandBuffer,
	parameters: Draw_Parameters,
) {
	assert(pipeline != nil && pipeline.handle != nil && pipeline.bind_draw != nil)
	pipeline.bind_draw(pipeline.user_data, command_buffer, parameters)
}

basic_pipeline_bind_draw :: proc(
	user_data: rawptr,
	command_buffer: ^sdl.GPUCommandBuffer,
	parameters: Draw_Parameters,
) {
	_ = user_data
	uniforms := shader_parameters.Triangle_Vertex_Uniform_Block {
		u_data = {mvp = parameters.view_projection * parameters.model_transform},
	}
	shader_parameters.triangle_vertex_push_uniform_block(command_buffer, &uniforms)
}

gfx_basic_pipeline :: proc(gfx: ^Gfx) -> Pipeline {
	vert_shader := shader.create_graphics(gfx.gpu, shader_parameters.triangle_vertex())
	frag_shader := shader.create_graphics(gfx.gpu, shader_parameters.triangle_fragment())
	assert(vert_shader != nil)
	assert(frag_shader != nil)
	defer {
		sdl.ReleaseGPUShader(gfx.gpu, vert_shader)
		sdl.ReleaseGPUShader(gfx.gpu, frag_shader)
	}

	vertex_attrs := shader_parameters.triangle_vertex_attributes(VertexData)

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
				vertex_attributes = &vertex_attrs[0],
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

	return {handle = pipeline, bind_draw = basic_pipeline_bind_draw}
}
