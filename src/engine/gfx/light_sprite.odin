package gfx

import goose "../../../third_party/goose/src"

// Light-sprite pipeline (src/engine/gfx/shaders/light_sprite.slang): additive HDR glows, depth-tested against the
// scene but not written, so overlapping glows add up. Shader params and bind_draw stay with the caller.
light_sprite_pipeline_create :: proc(
	gfx_ctx: ^Device,
	vertex: goose.GraphicsParameters,
	fragment: goose.GraphicsParameters,
	vertex_attributes: []goose.VertexAttribute,
	bind_draw: Pipeline_Bind_Draw_Proc,
	user_data: rawptr,
) -> Pipeline_Handle {
	return pipeline_create(
		gfx_ctx,
		{
			vertex = vertex,
			fragment = fragment,
			vertex_attributes = vertex_attributes,
			vertex_stride = u32(size_of(VertexData)),
			depth_test = true,
			depth_write = false,
			additive = true,
			cull_mode = .NONE, // billboards face the camera; either winding is fine
			bind_draw = bind_draw,
			user_data = user_data,
		},
	)
}
