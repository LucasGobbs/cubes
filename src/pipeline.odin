package main

import goose "goose"
import goose_sdl "goose/adapters/sdl_gpu"
import shader_parameters "shader_parameters"
import sdl "vendor:sdl3"

Draw_Parameters :: struct {
	view_projection: matrix[4, 4]f32,
	model_transform: matrix[4, 4]f32,
	material:        ^Material,
}

Pipeline_Bind_Material_Proc :: #type proc(
	user_data: rawptr,
	gfx: ^Gfx,
	pass: ^sdl.GPURenderPass,
	command_buffer: ^sdl.GPUCommandBuffer,
	material: ^Material,
)

Pipeline_Bind_Draw_Proc :: #type proc(
	user_data: rawptr,
	command_buffer: ^sdl.GPUCommandBuffer,
	parameters: Draw_Parameters,
)

Pipeline :: struct {
	handle:        ^sdl.GPUGraphicsPipeline,
	user_data:     rawptr,
	bind_material: Pipeline_Bind_Material_Proc,
	bind_draw:     Pipeline_Bind_Draw_Proc,
}

gfx_pipeline_store :: proc(gfx: ^Gfx, resource: Pipeline) -> Pipeline_Handle {
	assert(resource.handle != nil)
	handle := Pipeline_Handle(handle_pool_acquire(&gfx.pipeline_handles))
	index := Resource_Handle(handle).index
	if int(index) == len(gfx.pipelines) {
		append(&gfx.pipelines, resource)
	} else {
		gfx.pipelines[index] = resource
	}
	return handle
}

gfx_pipeline_get :: proc(gfx: ^Gfx, handle: Pipeline_Handle) -> ^Pipeline {
	raw := Resource_Handle(handle)
	assert(handle_pool_contains(&gfx.pipeline_handles, raw), "stale pipeline handle")
	return &gfx.pipelines[raw.index]
}

gfx_pipeline_destroy :: proc(gfx: ^Gfx, handle: Pipeline_Handle) {
	raw := Resource_Handle(handle)
	if !handle_pool_contains(&gfx.pipeline_handles, raw) do return
	resource := &gfx.pipelines[raw.index]
	if resource.handle != nil do sdl.ReleaseGPUGraphicsPipeline(gfx.gpu, resource.handle)
	resource^ = {}
	assert(handle_pool_release(&gfx.pipeline_handles, raw))
}

gfx_pipeline_bind_material :: proc(
	gfx: ^Gfx,
	handle: Pipeline_Handle,
	pass: ^sdl.GPURenderPass,
	command_buffer: ^sdl.GPUCommandBuffer,
	material: ^Material,
) {
	pipeline := gfx_pipeline_get(gfx, handle)
	assert(pipeline.bind_material != nil)
	pipeline.bind_material(pipeline.user_data, gfx, pass, command_buffer, material)
}

gfx_pipeline_bind_draw :: proc(
	gfx: ^Gfx,
	handle: Pipeline_Handle,
	command_buffer: ^sdl.GPUCommandBuffer,
	parameters: Draw_Parameters,
) {
	pipeline := gfx_pipeline_get(gfx, handle)
	assert(pipeline.bind_draw != nil)
	pipeline.bind_draw(pipeline.user_data, command_buffer, parameters)
}

textured_pipeline_bind_material :: proc(
	user_data: rawptr,
	gfx: ^Gfx,
	pass: ^sdl.GPURenderPass,
	command_buffer: ^sdl.GPUCommandBuffer,
	material: ^Material,
) {
	_, _ = user_data, command_buffer
	binding, ok := material_find_texture(material, shader_parameters.TRIANGLE_FRAGMENT_TEX)
	assert(ok, "textured material is missing its reflected texture binding")
	texture := gfx_texture_get(gfx, binding.texture)
	sampler := gfx_sampler_get(gfx, binding.sampler)
	goose_sdl.bind_sampler(
		pass,
		binding.texture_parameter,
		binding.sampler_parameter,
		texture.handle,
		sampler.handle,
	)
}

textured_pipeline_bind_draw :: proc(
	user_data: rawptr,
	command_buffer: ^sdl.GPUCommandBuffer,
	parameters: Draw_Parameters,
) {
	_ = user_data
	uniforms := shader_parameters.Triangle_Vertex_Uniform_Block {
		u_data = {mvp = parameters.view_projection * parameters.model_transform},
	}
	goose_sdl.push_uniform(
		command_buffer,
		shader_parameters.TRIANGLE_VERTEX_UNIFORM_BLOCK,
		&uniforms,
	)
}

unlit_pipeline_bind_material :: proc(
	user_data: rawptr,
	gfx: ^Gfx,
	pass: ^sdl.GPURenderPass,
	command_buffer: ^sdl.GPUCommandBuffer,
	material: ^Material,
) {
	_, _, _ = user_data, gfx, pass
	uniforms := shader_parameters.Unlit_Color_Fragment_Uniform_Block {
		data = {tint = material.tint},
	}
	goose_sdl.push_uniform(
		command_buffer,
		shader_parameters.UNLIT_COLOR_FRAGMENT_UNIFORM_BLOCK,
		&uniforms,
	)
}

unlit_pipeline_bind_draw :: proc(
	user_data: rawptr,
	command_buffer: ^sdl.GPUCommandBuffer,
	parameters: Draw_Parameters,
) {
	_ = user_data
	uniforms := shader_parameters.Unlit_Color_Vertex_Uniform_Block {
		data = {
			mvp = parameters.view_projection * parameters.model_transform,
			tint = parameters.material.tint,
		},
	}
	goose_sdl.push_uniform(
		command_buffer,
		shader_parameters.UNLIT_COLOR_VERTEX_UNIFORM_BLOCK,
		&uniforms,
	)
}

gfx_create_graphics_pipeline :: proc(
	gfx: ^Gfx,
	vertex_parameters: goose.Graphics_Parameters,
	fragment_parameters: goose.Graphics_Parameters,
	vertex_attributes: []sdl.GPUVertexAttribute,
	vertex_stride: u32,
) -> ^sdl.GPUGraphicsPipeline {
	assert(len(vertex_attributes) > 0)
	vert_shader := goose_sdl.create_graphics_shader(gfx.gpu, vertex_parameters)
	frag_shader := goose_sdl.create_graphics_shader(gfx.gpu, fragment_parameters)
	assert(vert_shader != nil && frag_shader != nil)
	defer {
		sdl.ReleaseGPUShader(gfx.gpu, vert_shader)
		sdl.ReleaseGPUShader(gfx.gpu, frag_shader)
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
						pitch = vertex_stride,
					}),
				num_vertex_attributes = u32(len(vertex_attributes)),
				vertex_attributes = raw_data(vertex_attributes),
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
	assert(pipeline != nil)
	return pipeline
}

gfx_pipeline_create_textured :: proc(gfx: ^Gfx) -> Pipeline_Handle {
	goose_attributes := shader_parameters.triangle_vertex_attributes(VertexData)
	attributes := goose_sdl.convert_vertex_attributes(goose_attributes[:], context.temp_allocator)
	native := gfx_create_graphics_pipeline(
		gfx,
		shader_parameters.triangle_vertex(),
		shader_parameters.triangle_fragment(),
		attributes[:],
		u32(size_of(VertexData)),
	)
	return gfx_pipeline_store(
		gfx,
		{
			handle = native,
			bind_material = textured_pipeline_bind_material,
			bind_draw = textured_pipeline_bind_draw,
		},
	)
}

gfx_pipeline_create_unlit :: proc(gfx: ^Gfx) -> Pipeline_Handle {
	goose_attributes := shader_parameters.unlit_color_vertex_attributes(VertexData)
	attributes := goose_sdl.convert_vertex_attributes(goose_attributes[:], context.temp_allocator)
	native := gfx_create_graphics_pipeline(
		gfx,
		shader_parameters.unlit_color_vertex(),
		shader_parameters.unlit_color_fragment(),
		attributes[:],
		u32(size_of(VertexData)),
	)
	return gfx_pipeline_store(
		gfx,
		{
			handle = native,
			bind_material = unlit_pipeline_bind_material,
			bind_draw = unlit_pipeline_bind_draw,
		},
	)
}
