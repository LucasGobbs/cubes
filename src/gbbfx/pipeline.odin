package gbbfx

import goose "../../third_party/goose/src"
import goose_adapters "../../third_party/goose/src/adapters"
import goose_sdl "sdl_gpu"
import sdl "vendor:sdl3"

Draw_Parameters :: struct {
	view_projection: matrix[4, 4]f32,
	model_transform: matrix[4, 4]f32,
	material:        ^Material,
	// Start of this run's transforms in the instance storage buffer
	// (instanced pipelines only; 0 otherwise).
	camera_position: [3]f32,
	first_instance:  u32,
	fog:             [4]f32, // rgb = linear fog color, a = view distance (<= 0 = off)
}

Draw_Context :: struct {
	_backend_command_buffer: rawptr,
}

Pipeline_Bind_Draw_Proc :: #type proc(
	user_data: rawptr,
	draw_context: ^Draw_Context,
	parameters: Draw_Parameters,
)

Pipeline_Bind_Skinned_Storage_Proc :: #type proc(
	gfx: ^Gfx,
	pass: ^sdl.GPURenderPass,
	transforms: Buffer_Handle,
	palettes: Buffer_Handle,
)

Graphics_Pipeline_Desc :: struct {
	vertex:            goose.GraphicsParameters,
	fragment:          goose.GraphicsParameters,
	vertex_attributes: []goose.VertexAttribute,
	vertex_stride:     u32,
	depth_test:        bool,
	depth_write:       bool,
	// Zero value (.INVALID) means .GREATER, the reverse-Z convention (see
	// camera_perspective). Use .GREATER_OR_EQUAL for geometry at exactly the
	// far plane, such as a skybox.
	depth_compare:     sdl.GPUCompareOp,
	// Alpha blending (src alpha / one-minus-src-alpha), for UI and
	// transparency. A pipeline with neither depth flag is created without a
	// depth-stencil target, matching depth-less overlay passes.
	blend:             bool,
	// Face culling. Zero values keep the previous behavior (no culling,
	// counter-clockwise front, which is glTF's outward winding); closed meshes
	// should cull .BACK.
	cull_mode:         sdl.GPUCullMode,
	front_face:        sdl.GPUFrontFace,
	// The shader reads per-instance data from a storage buffer by
	// SV_InstanceID, so the renderer may collapse runs of identical
	// (mesh, material) draw items into one instanced draw.
	instanced:         bool,
	// Skinned pipelines also read joint palettes from a second storage buffer
	// (see defaults.bind_textured_skinned_storage). Set together with instanced.
	skinned:           bool,
	// Only ever bound in passes that render to 1x targets (overlay/present
	// passes). Skips building the MSAA variant.
	single_sample:     bool,
	bind_draw:         Pipeline_Bind_Draw_Proc,
	bind_skinned_storage: Pipeline_Bind_Skinned_Storage_Proc,
	user_data:         rawptr,
}

Pipeline :: struct {
	// 1x variant: overlay/present passes and MSAA off.
	handle:      ^sdl.GPUGraphicsPipeline,
	// MSAA_SAMPLES variant for the scene pass; nil when single_sample or the
	// device lacks support.
	handle_msaa: ^sdl.GPUGraphicsPipeline,
	user_data: rawptr,
	bind_draw: Pipeline_Bind_Draw_Proc,
	bind_skinned_storage: Pipeline_Bind_Skinned_Storage_Proc,
	instanced: bool,
	skinned: bool,
}

draw_push_uniform :: proc(draw_context: ^Draw_Context, binding: goose.UniformBlock, data: ^$T) {
	assert(draw_context != nil && draw_context._backend_command_buffer != nil)
	command_buffer := cast(^sdl.GPUCommandBuffer)draw_context._backend_command_buffer
	goose_sdl.push_uniform(command_buffer, binding, data)
}

gfx_pipeline_create :: proc(gfx: ^Gfx, desc: Graphics_Pipeline_Desc) -> Pipeline_Handle {
	assert(desc.vertex.stage == .Vertex)
	assert(desc.fragment.stage == .Fragment)
	assert(len(desc.vertex_attributes) > 0 && desc.vertex_stride > 0)
	attributes, attributes_ok := goose_adapters.convert_vertex_attributes(
		desc.vertex_attributes,
		context.temp_allocator,
	)
	assert(attributes_ok)
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
	depth_compare := desc.depth_compare
	if depth_compare == .INVALID do depth_compare = .GREATER
	buffer_description := sdl.GPUVertexBufferDescription {
		slot  = 0,
		pitch = desc.vertex_stride,
	}
	info := sdl.GPUGraphicsPipelineCreateInfo {
			vertex_shader = vertex_shader,
			fragment_shader = fragment_shader,
			primitive_type = .TRIANGLELIST,
			vertex_input_state = {
				num_vertex_buffers = 1,
				vertex_buffer_descriptions = &buffer_description,
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
				compare_op = depth_compare,
			},
			target_info = {
				num_color_targets = 1,
				color_target_descriptions = &color_target,
				has_depth_stencil_target = has_depth,
				depth_stencil_format = .D32_FLOAT if has_depth else .INVALID,
			},
	}
	native := sdl.CreateGPUGraphicsPipeline(gfx.gpu, info)
	assert(native != nil)
	native_msaa: ^sdl.GPUGraphicsPipeline
	if !desc.single_sample && gfx.renderer.msaa_supported {
		info.multisample_state.sample_count = MSAA_SAMPLES
		native_msaa = sdl.CreateGPUGraphicsPipeline(gfx.gpu, info)
		assert(native_msaa != nil)
	}
	resource := Pipeline {
		handle      = native,
		handle_msaa = native_msaa,
		user_data = desc.user_data,
		bind_draw = desc.bind_draw,
		bind_skinned_storage = desc.bind_skinned_storage,
		instanced = desc.instanced,
		skinned = desc.skinned,
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

// Native pipeline for a pass: the MSAA variant when the pass is multisampled
// (and the pipeline has one), else the 1x variant.
pipeline_native :: proc(pipeline: ^Pipeline, msaa_pass: bool) -> ^sdl.GPUGraphicsPipeline {
	if msaa_pass && pipeline.handle_msaa != nil do return pipeline.handle_msaa
	return pipeline.handle
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
	if resource.handle_msaa != nil do sdl.ReleaseGPUGraphicsPipeline(gfx.gpu, resource.handle_msaa)
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
