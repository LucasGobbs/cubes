package gfx

import "core:math/linalg"

// Translucent pipeline: alpha blended, depth-tested but not depth-written,
// two-sided. Caller draws it on Render_Layer.TRANSPARENT.
create_glass_pipeline :: proc(gfx_ctx: ^Device) -> Pipeline_Handle {
	attributes := default_glass_vertex_attributes(VertexData)
	return pipeline_create(
		gfx_ctx,
		{
			vertex = default_glass_vertex(),
			fragment = default_glass_fragment(),
			vertex_attributes = attributes[:],
			vertex_stride = u32(size_of(VertexData)),
			depth_test = true,
			depth_write = false,
			cull_mode = .NONE,
			blend = true,
			bind_draw = bind_glass_draw,
		},
	)
}

// tint is an sRGB display color; rgb is converted to linear, alpha is base opacity and stays linear.
set_glass_color :: proc(material: ^Material, tint: [4]f32) {
	uniforms := DefaultGlassFragmentUniformBlock {
		data = {tint = color_srgb_to_linear(tint)},
	}
	material_set_uniform(material, DEFAULT_GLASS_FRAGMENT_UNIFORM_BLOCK, &uniforms)
}

bind_glass_draw :: proc(
	user_data: rawptr,
	draw_context: ^Draw_Context,
	parameters: Draw_Parameters,
) {
	_ = user_data
	data, ok := material_uniform_data(parameters.material, DEFAULT_GLASS_FRAGMENT_UNIFORM_BLOCK)
	assert(ok)
	fragment := cast(^DefaultGlassFragmentUniformBlock)raw_data(data)
	cam := parameters.camera_position
	uniforms := DefaultGlassVertexUniformBlock {
		data = {
			mvp           = parameters.view_projection * parameters.model_transform,
			model         = parameters.model_transform,
			normal_matrix = linalg.matrix4_inverse_transpose(parameters.model_transform),
			camera_pos    = {cam.x, cam.y, cam.z, 1},
			tint          = fragment.data.tint,
		},
	}
	draw_push_uniform(draw_context, DEFAULT_GLASS_VERTEX_UNIFORM_BLOCK, &uniforms)
}
