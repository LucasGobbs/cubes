package gfx

import goose "../../../third_party/goose/src"
import goose_adapters "../../../third_party/goose/src/adapters"
import goose_sdl "sdl_gpu"
import sdl "vendor:sdl3"

Draw_Parameters :: struct {
	view_projection:       matrix[4, 4]f32,
	model_transform: matrix[4, 4]f32,
	material:        ^Material,
	// Start of this run's transforms in the instance storage buffer
	// (instanced pipelines only; 0 otherwise).
	camera_position: [3]f32,
	first_instance:  u32,
	fog:                   [4]f32, // rgb = linear fog color, a = view distance (<= 0 = off)
	light_view_projection: matrix[4, 4]f32, // sun shadow map transform; valid when shadow_enabled
	shadow_enabled:        bool,
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
	gfx_ctx: ^Device,
	pass: ^sdl.GPURenderPass,
	transforms: Buffer_Handle,
	palettes: Buffer_Handle,
)

// Stencil test for depth-target pipelines. Zero value = off.
// Ops are per face (GPUDepthStencilState.front/back_stencil_state); masks are shared by both faces.
Stencil_Face_Desc :: struct {
	compare_op:    sdl.GPUCompareOp,
	pass_op:       sdl.GPUStencilOp,
	fail_op:       sdl.GPUStencilOp,
	depth_fail_op: sdl.GPUStencilOp,
}

Stencil_Desc :: struct {
	enabled:       bool,
	front:         Stencil_Face_Desc,
	back:          Stencil_Face_Desc,
	// Bits of the stored/reference value taking part in the test, and in writes.
	compare_mask:  u8,
	write_mask:    u8,
	// Bound with SetGPUStencilReference whenever the pipeline is bound.
	reference:     u8,
}

Graphics_Pipeline_Desc :: struct {
	vertex:            goose.GraphicsParameters,
	fragment:          goose.GraphicsParameters,
	vertex_attributes: []goose.VertexAttribute,
	// stride 0 + no attributes = vertex pulling from storage buffers. Set both or neither.
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
	// Additive blending (src SRC_ALPHA, dst ONE, ADD); alpha keeps dst alpha. Mutually exclusive with blend.
	additive:          bool,
	// Render target format; .INVALID (zero) = swapchain format. Set to
	// renderer.post_format for overlays that draw into postfx outputs.
	color_format:      sdl.GPUTextureFormat,
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
	// (see bind_textured_skinned_storage). Set together with instanced.
	skinned:           bool,
	// Only ever bound in passes that render to 1x targets (overlay/present
	// passes). Skips building the MSAA variant.
	single_sample:     bool,
	// Depth-only pipeline (shadow passes): no color target, so it binds to a pass with no color attachment.
	depth_only:        bool,
	// Hardware depth bias (shadow casters): constant in depth-resolution units, slope scaled by polygon slope. 0/0 = off.
	depth_bias_constant: f32,
	depth_bias_slope:    f32,
	// Stencil test. Zero value = off (depth test only).
	stencil:             Stencil_Desc,
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
	stencil_enabled:   bool,
	stencil_reference: u8,
	pulled:            bool, // vertex-pulled: vertices come from a storage buffer (no vertex attributes)
}

draw_push_uniform :: proc(draw_context: ^Draw_Context, binding: goose.UniformBlock, data: ^$T) {
	assert(draw_context != nil && draw_context._backend_command_buffer != nil)
	command_buffer := cast(^sdl.GPUCommandBuffer)draw_context._backend_command_buffer
	goose_sdl.push_uniform(command_buffer, binding, data)
}

pipeline_create :: proc(gfx_ctx: ^Device, desc: Graphics_Pipeline_Desc) -> Pipeline_Handle {
	assert(desc.vertex.stage == .Vertex)
	assert(desc.fragment.stage == .Fragment)
	assert((desc.vertex_stride == 0) == (len(desc.vertex_attributes) == 0))
	assert(!(desc.blend && desc.additive))
	attributes, attributes_ok := goose_adapters.convert_vertex_attributes(
		desc.vertex_attributes,
		context.temp_allocator,
	)
	assert(attributes_ok)
	vertex_shader := goose_sdl.create_graphics_shader(gfx_ctx.gpu, desc.vertex)
	fragment_shader := goose_sdl.create_graphics_shader(gfx_ctx.gpu, desc.fragment)
	assert(vertex_shader != nil && fragment_shader != nil)
	defer {
		sdl.ReleaseGPUShader(gfx_ctx.gpu, vertex_shader)
		sdl.ReleaseGPUShader(gfx_ctx.gpu, fragment_shader)
	}

	color_target := sdl.GPUColorTargetDescription {
		format = desc.color_format if desc.color_format != .INVALID else sdl.GetGPUSwapchainTextureFormat(gfx_ctx.gpu, gfx_ctx.window),
	}
	if desc.additive {
		color_target.blend_state = {
			src_color_blendfactor = .SRC_ALPHA,
			dst_color_blendfactor = .ONE,
			color_blend_op = .ADD,
			src_alpha_blendfactor = .ZERO,
			dst_alpha_blendfactor = .ONE,
			alpha_blend_op = .ADD,
		}
		color_target.blend_state.enable_blend = true
	} else if desc.blend {
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
	assert(!desc.stencil.enabled || (has_depth && !desc.depth_only))
	// Shadow maps stay D32; every other depth pipeline matches the scene depth target.
	depth_format := sdl.GPUTextureFormat.INVALID
	if has_depth {
		depth_format = .D32_FLOAT if desc.depth_only else gfx_ctx.renderer.scene_depth_format
	}
	depth_compare := desc.depth_compare
	if depth_compare == .INVALID do depth_compare = .GREATER
	buffer_description := sdl.GPUVertexBufferDescription {
		slot  = 0,
		pitch = desc.vertex_stride,
	}
	// Vertex-pulled pipelines bind no vertex buffers; the shader reads storage buffers by SV_VertexID.
	num_vertex_buffers: u32 = 1 if desc.vertex_stride > 0 else 0
	vertex_buffer_descriptions: ^sdl.GPUVertexBufferDescription = &buffer_description if desc.vertex_stride > 0 else nil
	info := sdl.GPUGraphicsPipelineCreateInfo {
			vertex_shader = vertex_shader,
			fragment_shader = fragment_shader,
			primitive_type = .TRIANGLELIST,
			vertex_input_state = {
				num_vertex_buffers = num_vertex_buffers,
				vertex_buffer_descriptions = vertex_buffer_descriptions,
				num_vertex_attributes = u32(len(attributes)),
				vertex_attributes = raw_data(attributes),
			},
			rasterizer_state = {
				cull_mode = desc.cull_mode,
				enable_depth_bias = desc.depth_bias_constant != 0 || desc.depth_bias_slope != 0,
				depth_bias_constant_factor = desc.depth_bias_constant,
				depth_bias_slope_factor = desc.depth_bias_slope,
				front_face = desc.front_face,
			},
			depth_stencil_state = {
				enable_depth_test = desc.depth_test,
				enable_depth_write = desc.depth_write,
				compare_op = depth_compare,
				enable_stencil_test = desc.stencil.enabled,
				front_stencil_state = {
					compare_op    = desc.stencil.front.compare_op,
					pass_op       = desc.stencil.front.pass_op,
					fail_op       = desc.stencil.front.fail_op,
					depth_fail_op = desc.stencil.front.depth_fail_op,
				},
				back_stencil_state = {
					compare_op    = desc.stencil.back.compare_op,
					pass_op       = desc.stencil.back.pass_op,
					fail_op       = desc.stencil.back.fail_op,
					depth_fail_op = desc.stencil.back.depth_fail_op,
				},
				compare_mask = desc.stencil.compare_mask,
				write_mask = desc.stencil.write_mask,
			},
			target_info = {
				num_color_targets = 0 if desc.depth_only else 1,
				color_target_descriptions = &color_target,
				has_depth_stencil_target = has_depth,
				depth_stencil_format = depth_format,
			},
	}
	native := sdl.CreateGPUGraphicsPipeline(gfx_ctx.gpu, info)
	assert(native != nil)
	native_msaa: ^sdl.GPUGraphicsPipeline
	if !desc.single_sample && gfx_ctx.renderer.msaa_supported {
		info.multisample_state.sample_count = MSAA_SAMPLES
		native_msaa = sdl.CreateGPUGraphicsPipeline(gfx_ctx.gpu, info)
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
		stencil_enabled = desc.stencil.enabled,
		stencil_reference = desc.stencil.reference,
		pulled = desc.vertex_stride == 0,
	}
	handle := Pipeline_Handle(handle_pool_acquire(&gfx_ctx.pipeline_handles))
	index := Resource_Handle(handle).index
	if int(index) == len(gfx_ctx.pipelines) {
		append(&gfx_ctx.pipelines, resource)
	} else {
		gfx_ctx.pipelines[index] = resource
	}
	scope_track(gfx_ctx, .Pipeline, Resource_Handle(handle))
	return handle
}

// Native pipeline for a pass: the MSAA variant when the pass is multisampled
// (and the pipeline has one), else the 1x variant.
pipeline_native :: proc(pipeline: ^Pipeline, msaa_pass: bool) -> ^sdl.GPUGraphicsPipeline {
	if msaa_pass && pipeline.handle_msaa != nil do return pipeline.handle_msaa
	return pipeline.handle
}

// Binds the pipeline for a pass; sets the stencil reference only when the pipeline tests stencil.
pipeline_bind_native :: proc(pass: ^sdl.GPURenderPass, pipeline: ^Pipeline, msaa_pass: bool) {
	sdl.BindGPUGraphicsPipeline(pass, pipeline_native(pipeline, msaa_pass))
	if pipeline.stencil_enabled do sdl.SetGPUStencilReference(pass, pipeline.stencil_reference)
}

pipeline_get :: proc(gfx_ctx: ^Device, handle: Pipeline_Handle) -> ^Pipeline {
	raw := Resource_Handle(handle)
	assert(handle_pool_contains(&gfx_ctx.pipeline_handles, raw), "stale pipeline handle")
	return &gfx_ctx.pipelines[raw.index]
}

pipeline_destroy :: proc(gfx_ctx: ^Device, handle: Pipeline_Handle) {
	raw := Resource_Handle(handle)
	if !handle_pool_contains(&gfx_ctx.pipeline_handles, raw) do return
	scope_untrack(gfx_ctx, .Pipeline, raw)
	resource := &gfx_ctx.pipelines[raw.index]
	if resource.handle != nil do sdl.ReleaseGPUGraphicsPipeline(gfx_ctx.gpu, resource.handle)
	if resource.handle_msaa != nil do sdl.ReleaseGPUGraphicsPipeline(gfx_ctx.gpu, resource.handle_msaa)
	resource^ = {}
	assert(handle_pool_release(&gfx_ctx.pipeline_handles, raw))
}

pipeline_bind_material :: proc(
	gfx_ctx: ^Device,
	pass: ^sdl.GPURenderPass,
	command_buffer: ^sdl.GPUCommandBuffer,
	material: ^Material,
) {
	for &binding in material.textures {
		texture := texture_get(gfx_ctx, binding.texture)
		sampler := sampler_get(gfx_ctx, binding.sampler)
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

pipeline_bind_draw :: proc(
	gfx_ctx: ^Device,
	handle: Pipeline_Handle,
	command_buffer: ^sdl.GPUCommandBuffer,
	parameters: Draw_Parameters,
) {
	pipeline := pipeline_get(gfx_ctx, handle)
	if pipeline.bind_draw == nil do return
	draw_context := Draw_Context {
		_backend_command_buffer = rawptr(command_buffer),
	}
	pipeline.bind_draw(pipeline.user_data, &draw_context, parameters)
}
