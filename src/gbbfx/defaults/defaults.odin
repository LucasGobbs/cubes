package defaults

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
			bind_draw = bind_textured_draw,
		},
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

set_unlit_color :: proc(material: ^gbbfx.Material, tint: [4]f32) {
	uniforms := Default_Unlit_Color_Fragment_Uniform_Block {
		data = {tint = tint},
	}
	gbbfx.material_set_uniform(material, DEFAULT_UNLIT_COLOR_FRAGMENT_UNIFORM_BLOCK, &uniforms)
}

bind_textured_draw :: proc(
	user_data: rawptr,
	draw_context: ^gbbfx.Draw_Context,
	parameters: gbbfx.Draw_Parameters,
) {
	_ = user_data
	uniforms := Default_Textured_Vertex_Uniform_Block {
		data = {mvp = parameters.view_projection * parameters.model_transform},
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
	fragment := cast(^Default_Unlit_Color_Fragment_Uniform_Block)raw_data(data)
	uniforms := Default_Unlit_Color_Vertex_Uniform_Block {
		data = {
			mvp = parameters.view_projection * parameters.model_transform,
			tint = fragment.data.tint,
		},
	}
	gbbfx.draw_push_uniform(draw_context, DEFAULT_UNLIT_COLOR_VERTEX_UNIFORM_BLOCK, &uniforms)
}
