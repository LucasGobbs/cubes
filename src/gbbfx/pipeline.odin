package gbbfx

import goose "../goose"
import goose_sdl "../goose/adapters/sdl_gpu"
import sdl "vendor:sdl3"

Draw_Parameters :: struct {
	view_projection: matrix[4, 4]f32,
	model_transform: matrix[4, 4]f32,
	material:        ^Material,
}

Draw_Context :: struct {
	_backend_command_buffer: rawptr,
}

Pipeline_Bind_Draw_Proc :: #type proc(
	user_data: rawptr,
	draw_context: ^Draw_Context,
	parameters: Draw_Parameters,
)

Graphics_Pipeline_Desc :: struct {
	vertex:            goose.Graphics_Parameters,
	fragment:          goose.Graphics_Parameters,
	vertex_attributes: []goose.Vertex_Attribute,
	vertex_stride:     u32,
	depth_test:        bool,
	depth_write:       bool,
	// Alpha blending (src alpha / one-minus-src-alpha), for UI and
	// transparency. A pipeline with neither depth flag is created without a
	// depth-stencil target, matching depth-less overlay passes.
	blend:             bool,
	// Face culling. Zero values keep the previous behavior (no culling,
	// counter-clockwise front); closed meshes should cull .BACK.
	cull_mode:         sdl.GPUCullMode,
	front_face:        sdl.GPUFrontFace,
	bind_draw:         Pipeline_Bind_Draw_Proc,
	user_data:         rawptr,
}

Pipeline :: struct {
	handle:    ^sdl.GPUGraphicsPipeline,
	user_data: rawptr,
	bind_draw: Pipeline_Bind_Draw_Proc,
}

draw_push_uniform :: proc(draw_context: ^Draw_Context, binding: goose.Uniform_Block, data: ^$T) {
	assert(draw_context != nil && draw_context._backend_command_buffer != nil)
	command_buffer := cast(^sdl.GPUCommandBuffer)draw_context._backend_command_buffer
	goose_sdl.push_uniform(command_buffer, binding, data)
}

gfx_pipeline_create :: proc(gfx: ^Gfx, desc: Graphics_Pipeline_Desc) -> Pipeline_Handle {
	assert(desc.vertex.stage == .Vertex)
	assert(desc.fragment.stage == .Fragment)
	assert(len(desc.vertex_attributes) > 0 && desc.vertex_stride > 0)
	attributes := goose_sdl.convert_vertex_attributes(
		desc.vertex_attributes,
		context.temp_allocator,
	)
	vertex_shader := goose_sdl.create_graphics_shader(gfx.gpu, desc.vertex)
	fragment_shader := goose_sdl.create_graphics_shader(gfx.gpu, desc.fragment)
	assert(vertex_shader != nil && fragment_shader != nil)
	defer {
		sdl.ReleaseGPUShader(gfx.gpu, vertex_shader)
		sdl.ReleaseGPUShader(gfx.gpu, fragment_shader)
	}

	color_target := sdl.GPUColorTargetDescription {
		format = sdl.GetGPUSwapchainTextureFormat(gfx.gpu, gfx.window),
	}
	if desc.blend {
		color_target.blend_state = {
			src_color_blendfactor = .SRC_ALPHA,
			dst_color_blendfactor = .ONE_MINUS_SRC_ALPHA,
			color_blend_op = .ADD,
			src_alpha_blendfactor = .SRC_ALPHA,
			dst_alpha_blendfactor = .ONE_MINUS_SRC_ALPHA,
			alpha_blend_op = .ADD,
		}
		color_target.blend_state.enable_blend = true
	}
	has_depth := desc.depth_test || desc.depth_write
	native := sdl.CreateGPUGraphicsPipeline(
		gfx.gpu,
		{
			vertex_shader = vertex_shader,
			fragment_shader = fragment_shader,
			primitive_type = .TRIANGLELIST,
			vertex_input_state = {
				num_vertex_buffers = 1,
				vertex_buffer_descriptions = &(sdl.GPUVertexBufferDescription {
						slot = 0,
						pitch = desc.vertex_stride,
					}),
				num_vertex_attributes = u32(len(attributes)),
				vertex_attributes = raw_data(attributes),
			},
			rasterizer_state = {
				cull_mode = desc.cull_mode,
				front_face = desc.front_face,
			},
			depth_stencil_state = {
				enable_depth_test = desc.depth_test,
				enable_depth_write = desc.depth_write,
				compare_op = .LESS,
			},
			target_info = {
				num_color_targets = 1,
				color_target_descriptions = &color_target,
				has_depth_stencil_target = has_depth,
				depth_stencil_format = .D32_FLOAT if has_depth else .INVALID,
			},
		},
	)
	assert(native != nil)
	resource := Pipeline {
		handle    = native,
		user_data = desc.user_data,
		bind_draw = desc.bind_draw,
	}
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
	pass: ^sdl.GPURenderPass,
	command_buffer: ^sdl.GPUCommandBuffer,
	material: ^Material,
) {
	for &binding in material.textures {
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
	for &binding in material.uniforms {
		goose_sdl.push_uniform_data(
			command_buffer,
			binding.parameter,
			raw_data(binding.data),
			u32(len(binding.data)),
		)
	}
}

gfx_pipeline_bind_draw :: proc(
	gfx: ^Gfx,
	handle: Pipeline_Handle,
	command_buffer: ^sdl.GPUCommandBuffer,
	parameters: Draw_Parameters,
) {
	pipeline := gfx_pipeline_get(gfx, handle)
	if pipeline.bind_draw == nil do return
	draw_context := Draw_Context {
		_backend_command_buffer = rawptr(command_buffer),
	}
	pipeline.bind_draw(pipeline.user_data, &draw_context, parameters)
}
