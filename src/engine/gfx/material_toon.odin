package gfx

import "core:math/linalg"

create_toon_pipeline :: proc(gfx_ctx: ^Device) -> Pipeline_Handle {
	attributes := default_toon_vertex_attributes(VertexData)
	return pipeline_create(
		gfx_ctx,
		{
			vertex = default_toon_vertex(),
			fragment = default_toon_fragment(),
			vertex_attributes = attributes[:],
			vertex_stride = u32(size_of(VertexData)),
			depth_test = true,
			depth_write = true,
			cull_mode = .BACK,
			bind_draw = bind_toon_draw,
		},
	)
}

bind_toon_draw :: proc(
	user_data: rawptr,
	draw_context: ^Draw_Context,
	parameters: Draw_Parameters,
) {
	_ = user_data
	uniforms := DefaultToonVertexUniformBlock {
		data = {
			mvp           = parameters.view_projection * parameters.model_transform,
			normal_matrix = linalg.matrix4_inverse_transpose(parameters.model_transform),
		},
	}
	draw_push_uniform(draw_context, DEFAULT_TOON_VERTEX_UNIFORM_BLOCK, &uniforms)
}

bind_toon_material :: proc(
	material: ^Material,
	texture: Texture_Handle,
	sampler: Sampler_Handle,
) {
	material_bind_texture(
		material,
		DEFAULT_TOON_FRAGMENT_TEX,
		DEFAULT_TOON_FRAGMENT_TEX_SAMPLER,
		texture,
		sampler,
	)
}
