// Test gallery: a row of generated buildings, one kind per slot, all textured with the window atlas. One mesh, one draw.
package city

import engine "../../engine"
import gfx "../../engine/gfx"
import shader_parameters "../../shader_parameters"

GALLERY_BUILDING_COUNT :: 8
GALLERY_SPACING :: 36 // centre to centre along X; 12 units between footprints
GALLERY_FOOTPRINT :: [2]f32{24, 24}
GALLERY_STORIES_MIN :: 20
GALLERY_STORIES_MAX :: 32

gallery_pipeline_create :: proc(gfx_ctx: ^gfx.Device) -> gfx.Pipeline_Handle {
	attributes := shader_parameters.city_vertex_attributes(gfx.VertexData)
	return gfx.pipeline_create(
		gfx_ctx,
		{
			vertex = shader_parameters.city_vertex(),
			fragment = shader_parameters.city_fragment(),
			vertex_attributes = attributes[:],
			vertex_stride = u32(size_of(gfx.VertexData)),
			depth_test = true,
			depth_write = true,
			cull_mode = .BACK,
			bind_draw = gallery_bind_draw,
		},
	)
}

gallery_bind_draw :: proc(user_data: rawptr, draw_context: ^gfx.Draw_Context, parameters: gfx.Draw_Parameters) {
	uniforms := shader_parameters.CityVertexUniforms {
		mvp = parameters.view_projection * parameters.model_transform,
	}
	gfx.draw_push_uniform(draw_context, shader_parameters.CITY_VERTEX_UNIFORM_BLOCK, &uniforms)
}

// Slot i: cube, blocky, modern, classic, repeating.
gallery_generator :: proc(slot: int) -> Building_Proc {
	switch slot % 4 {
	case 0:
		return building_cube
	case 1:
		return building_blocky
	case 2:
		return building_modern
	}
	return building_classic
}

// Buildings stand on y = 0, centred on z = 0, the row centred on x = 0. Same seed, same row.
gallery_build :: proc(seed: u32) -> Mesh_Builder {
	b: Mesh_Builder
	rng := rng_seed(seed)
	for i in 0 ..< GALLERY_BUILDING_COUNT {
		x := f32(2 * i - (GALLERY_BUILDING_COUNT - 1)) * GALLERY_SPACING / 2
		stories := rng_int(&rng, GALLERY_STORIES_MIN, GALLERY_STORIES_MAX)
		gallery_generator(i)(&b, &rng, {x, 0, 0}, GALLERY_FOOTPRINT, stories)
	}
	return b
}

// Spawns the row as one Raw_Draw; the engine copies the mesh at spawn, so the builder is freed here.
gallery_spawn :: proc(state: ^City_State) {
	b := gallery_build(state.seed)
	state.gallery = engine.spawn(&state.world, engine.Raw_Draw{mesh = builder_to_mesh_data(&b), material = &state.material})
	builder_destroy(&b)
}

gallery_despawn :: proc(state: ^City_State) {
	engine.world_destroy_actor(&state.world, state.gallery)
}
