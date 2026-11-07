package defaults

import "core:math/linalg"
import sdl "vendor:sdl3"
import gbbfx ".."

create_textured_pipeline :: proc(gfx: ^gbbfx.Gfx) -> gbbfx.Pipeline_Handle {
	attributes := default_textured_vertex_attributes(gbbfx.VertexData)
	return gbbfx.gfx_pipeline_create(
		gfx,
		{
			vertex = default_textured_vertex(),
			fragment = default_textured_fragment(),
			vertex_attributes = attributes[:],
			vertex_stride = u32(size_of(gbbfx.VertexData)),
			depth_test = true,
			depth_write = true,
			cull_mode = .BACK,
			bind_draw = bind_textured_draw,
		},
	)
}

create_unlit_pipeline :: proc(gfx: ^gbbfx.Gfx) -> gbbfx.Pipeline_Handle {
	attributes := default_unlit_color_vertex_attributes(gbbfx.VertexData)
	return gbbfx.gfx_pipeline_create(
		gfx,
		{
			vertex = default_unlit_color_vertex(),
			fragment = default_unlit_color_fragment(),
			vertex_attributes = attributes[:],
			vertex_stride = u32(size_of(gbbfx.VertexData)),
			depth_test = true,
			depth_write = true,
			cull_mode = .BACK,
			bind_draw = bind_unlit_draw,
		},
	)
}

// Textured pipeline for screen-space overlays: no depth, alpha blending.
// Vertices are expected in clip space with an identity view-projection
// (see renderer_begin_overlay_pass).
create_textured_overlay_pipeline :: proc(gfx: ^gbbfx.Gfx) -> gbbfx.Pipeline_Handle {
	attributes := default_textured_vertex_attributes(gbbfx.VertexData)
	return gbbfx.gfx_pipeline_create(
		gfx,
		{
			vertex = default_textured_vertex(),
			fragment = default_textured_fragment(),
			vertex_attributes = attributes[:],
			vertex_stride = u32(size_of(gbbfx.VertexData)),
			depth_test = false,
			depth_write = false,
			blend = true,
			single_sample = true, // drawn in 1x overlay/present passes
			bind_draw = bind_textured_draw,
		},
	)
}

// Instanced textured pipeline: the renderer collapses runs of identical
// (mesh, material) items into one draw; per-instance transforms arrive via
// the renderer's storage buffer, so bind_draw only pushes view_projection.
create_textured_instanced_pipeline :: proc(gfx: ^gbbfx.Gfx) -> gbbfx.Pipeline_Handle {
	attributes := default_textured_instanced_vertex_attributes(gbbfx.VertexData)
	return gbbfx.gfx_pipeline_create(
		gfx,
		{
			vertex = default_textured_instanced_vertex(),
			fragment = default_textured_instanced_fragment(),
			vertex_attributes = attributes[:],
			vertex_stride = u32(size_of(gbbfx.VertexData)),
			depth_test = true,
			depth_write = true,
			cull_mode = .BACK,
			instanced = true,
			bind_draw = bind_textured_instanced_draw,
		},
	)
}

// Skinned textured pipeline: bind-pose vertices plus joint indices and weights.
// Skinned runs are drawn with bind_textured_skinned_storage supplying the
// per-instance transforms and joint palettes.
create_textured_skinned_pipeline :: proc(gfx: ^gbbfx.Gfx) -> gbbfx.Pipeline_Handle {
	attributes := default_textured_skinned_vertex_attributes(gbbfx.SkinnedVertexData)
	return gbbfx.gfx_pipeline_create(
		gfx,
		{
			vertex = default_textured_skinned_vertex(),
			fragment = default_textured_skinned_fragment(),
			vertex_attributes = attributes[:],
			vertex_stride = u32(size_of(gbbfx.SkinnedVertexData)),
			depth_test = true,
			depth_write = true,
			cull_mode = .BACK,
			instanced = true,
			skinned = true,
			bind_draw = bind_textured_skinned_draw,
			bind_skinned_storage = bind_textured_skinned_storage,
		},
	)
}

bind_textured_instanced_draw :: proc(
	user_data: rawptr,
	draw_context: ^gbbfx.Draw_Context,
	parameters: gbbfx.Draw_Parameters,
) {
	_ = user_data
	uniforms := DefaultTexturedInstancedVertexUniformBlock {
		data = {
			view_projection = parameters.view_projection,
			first_instance = parameters.first_instance,
			camera_position = parameters.camera_position,
			fog = parameters.fog,
		},
	}
	gbbfx.draw_push_uniform(
		draw_context,
		DEFAULT_TEXTURED_INSTANCED_VERTEX_UNIFORM_BLOCK,
		&uniforms,
	)
}

// Same texture bindings as bind_textured_material but referencing the
// instanced shader's constants.
bind_textured_instanced_material :: proc(
	material: ^gbbfx.Material,
	texture: gbbfx.Texture_Handle,
	sampler: gbbfx.Sampler_Handle,
) {
	gbbfx.material_bind_texture(
		material,
		DEFAULT_TEXTURED_INSTANCED_FRAGMENT_TEX,
		DEFAULT_TEXTURED_INSTANCED_FRAGMENT_TEX_SAMPLER,
		texture,
		sampler,
	)
}

bind_textured_skinned_draw :: proc(
	user_data: rawptr,
	draw_context: ^gbbfx.Draw_Context,
	parameters: gbbfx.Draw_Parameters,
) {
	_ = user_data
	uniforms := DefaultTexturedSkinnedVertexUniformBlock {
		data = {
			view_projection = parameters.view_projection,
			first_instance = parameters.first_instance,
			camera_position = parameters.camera_position,
			fog = parameters.fog,
		},
	}
	gbbfx.draw_push_uniform(draw_context, DEFAULT_TEXTURED_SKINNED_VERTEX_UNIFORM_BLOCK, &uniforms)
}

bind_textured_skinned_material :: proc(
	material: ^gbbfx.Material,
	texture: gbbfx.Texture_Handle,
	sampler: gbbfx.Sampler_Handle,
) {
	gbbfx.material_bind_texture(
		material,
		DEFAULT_TEXTURED_SKINNED_FRAGMENT_TEX,
		DEFAULT_TEXTURED_SKINNED_FRAGMENT_TEX_SAMPLER,
		texture,
		sampler,
	)
}

// Binds the skinned shader's two vertex storage buffers for the current pass,
// at the slots the generated parameters declare: transforms (slot 0) and
// palettes (slot 1). For a skinned run, SV_InstanceID + first_instance selects
// transforms[i] and palettes[i * MAX_JOINTS ..< (i + 1) * MAX_JOINTS], so both
// buffers must be laid out with the same instance index. Binding replaces the
// pass's slot 0, so rebind the static instance buffer before later static runs.
bind_textured_skinned_storage :: proc(
	gfx: ^gbbfx.Gfx,
	pass: ^sdl.GPURenderPass,
	transforms: gbbfx.Buffer_Handle,
	palettes: gbbfx.Buffer_Handle,
) {
	transform_buffer := gbbfx.gfx_buffer_get(gfx, transforms)
	palette_buffer := gbbfx.gfx_buffer_get(gfx, palettes)
	sdl.BindGPUVertexStorageBuffers(
		pass,
		DEFAULT_TEXTURED_SKINNED_VERTEX_INSTANCE_TRANSFORMS.location.slot,
		&transform_buffer.handle,
		1,
	)
	sdl.BindGPUVertexStorageBuffers(
		pass,
		DEFAULT_TEXTURED_SKINNED_VERTEX_PALETTES.location.slot,
		&palette_buffer.handle,
		1,
	)
}

bind_textured_material :: proc(
	material: ^gbbfx.Material,
	texture: gbbfx.Texture_Handle,
	sampler: gbbfx.Sampler_Handle,
) {
	gbbfx.material_bind_texture(
		material,
		DEFAULT_TEXTURED_FRAGMENT_TEX,
		DEFAULT_TEXTURED_FRAGMENT_TEX_SAMPLER,
		texture,
		sampler,
	)
}

// tint is an sRGB display color (as an artist or the editor sliders write it);
// the shader works in linear space, so it is converted here.
set_unlit_color :: proc(material: ^gbbfx.Material, tint: [4]f32) {
	uniforms := DefaultUnlitColorFragmentUniformBlock {
		data = {tint = gbbfx.color_srgb_to_linear(tint)},
	}
	gbbfx.material_set_uniform(material, DEFAULT_UNLIT_COLOR_FRAGMENT_UNIFORM_BLOCK, &uniforms)
}

bind_textured_draw :: proc(
	user_data: rawptr,
	draw_context: ^gbbfx.Draw_Context,
	parameters: gbbfx.Draw_Parameters,
) {
	_ = user_data
	uniforms := DefaultTexturedVertexUniformBlock {
		data = {
			mvp           = parameters.view_projection * parameters.model_transform,
			normal_matrix = linalg.matrix4_inverse_transpose(parameters.model_transform),
		},
	}
	gbbfx.draw_push_uniform(draw_context, DEFAULT_TEXTURED_VERTEX_UNIFORM_BLOCK, &uniforms)
}

bind_unlit_draw :: proc(
	user_data: rawptr,
	draw_context: ^gbbfx.Draw_Context,
	parameters: gbbfx.Draw_Parameters,
) {
	_ = user_data
	data, ok := gbbfx.material_uniform_data(
		parameters.material,
		DEFAULT_UNLIT_COLOR_FRAGMENT_UNIFORM_BLOCK,
	)
	assert(ok)
	fragment := cast(^DefaultUnlitColorFragmentUniformBlock)raw_data(data)
	uniforms := DefaultUnlitColorVertexUniformBlock {
		data = {
			mvp = parameters.view_projection * parameters.model_transform,
			tint = fragment.data.tint,
		},
	}
	gbbfx.draw_push_uniform(draw_context, DEFAULT_UNLIT_COLOR_VERTEX_UNIFORM_BLOCK, &uniforms)
}
