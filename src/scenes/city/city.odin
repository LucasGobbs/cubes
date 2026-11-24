// Whole-city mesh from the plan: every building in one Mesh_Builder, one Raw_Draw. The dev view adds the streets
// as a second Raw_Draw.
package city

import engine "../../engine"
import gfx "../../engine/gfx"
import shader_parameters "../../shader_parameters"
import "core:log"
import "core:time"

ROAD_COLOR :: [4]f32{0.15, 0.35, 1, 1}
ROAD_HEIGHT :: 0.05 // above the ground plane so the streets never z-fight with it
// Golden-ratio multiplier: spreads per-building seeds across the u32 range.
BUILDING_SEED_MIX :: 0x9E3779B9

city_pipeline_create :: proc(gfx_ctx: ^gfx.Device) -> gfx.Pipeline_Handle {
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
			bind_draw = city_bind_draw,
		},
	)
}

city_bind_draw :: proc(user_data: rawptr, draw_context: ^gfx.Draw_Context, parameters: gfx.Draw_Parameters) {
	uniforms := shader_parameters.CityVertexUniforms {
		mvp = parameters.view_projection * parameters.model_transform,
	}
	gfx.draw_push_uniform(draw_context, shader_parameters.CITY_VERTEX_UNIFORM_BLOCK, &uniforms)
}

building_proc :: proc(kind: Building_Kind) -> Building_Proc {
	switch kind {
	case .Cube:
		return building_cube
	case .Blocky:
		return building_blocky
	case .Modern:
		return building_modern
	case .Classic:
		return building_classic
	}
	unreachable()
}

// Each building seeds its own generator from its index, so the mesh does not depend on generation order.
city_build_mesh :: proc(p: ^Plan, seed: u32) -> Mesh_Builder {
	b: Mesh_Builder
	reserve(&b.vertices, len(p.buildings) * 64)
	reserve(&b.indices, len(p.buildings) * 96)
	for plot, i in p.buildings {
		rng := rng_seed(seed ~ (u32(i + 1) * BUILDING_SEED_MIX))
		rng_u32(&rng) // first output of a near-zero xorshift state is weakly mixed
		origin := Vec3{f32(plot.x) + f32(plot.w) / 2, 0, f32(plot.z) + f32(plot.d) / 2}
		building_proc(plot.kind)(&b, &rng, origin, {f32(plot.w), f32(plot.d)}, int(plot.stories))
	}
	return b
}

city_build_roads :: proc(p: ^Plan) -> Mesh_Builder {
	b: Mesh_Builder
	for r in p.roads {
		x0, x1 := f32(r.x0), f32(r.x1)
		z0, z1 := f32(r.z0), f32(r.z1)
		builder_quad(
			&b,
			{x0, ROAD_HEIGHT, z0},
			{x0, ROAD_HEIGHT, z1},
			{x1, ROAD_HEIGHT, z1},
			{x1, ROAD_HEIGHT, z0},
			{},
			{},
			ROAD_COLOR,
		)
	}
	return b
}

// Spawns the buildings as one Raw_Draw; the engine copies the mesh at spawn, so the builder is freed here.
city_spawn :: proc(state: ^City_State) {
	t := time.tick_now()
	b := city_build_mesh(&state.plan, state.seed)
	ms := build_ms(t)
	state.city = engine.spawn(&state.world, engine.Raw_Draw{mesh = builder_to_mesh_data(&b), material = &state.material})
	log.infof("city: mesh %v vertices, %v indices, build %.1f ms", len(b.vertices), len(b.indices), ms)
	builder_destroy(&b)
}

city_despawn :: proc(state: ^City_State) {
	engine.world_destroy_actor(&state.world, state.city)
}

city_spawn_roads :: proc(state: ^City_State) {
	b := city_build_roads(&state.plan)
	state.roads = engine.spawn(&state.world, engine.Raw_Draw{mesh = builder_to_mesh_data(&b), material = &state.road_material})
	builder_destroy(&b)
}

city_despawn_roads :: proc(state: ^City_State) {
	engine.world_destroy_actor(&state.world, state.roads)
}

// Dev view: streets on or off.
city_set_dev :: proc(state: ^City_State, renderer: ^gfx.Renderer, dev: bool) {
	state.dev = dev
	if dev {
		city_spawn_roads(state)
		renderer.clear_color = CITY_CLEAR_COLOR
	} else {
		city_despawn_roads(state)
		renderer.clear_color = CITY_NIGHT_COLOR
	}
}

// Re-plans and re-spawns the city for state.seed, keeping the dev overlay in step.
city_rebuild :: proc(state: ^City_State) {
	city_despawn(state)
	if state.dev do city_despawn_roads(state)
	plan_destroy(&state.plan)
	state.plan = city_plan(state.seed)
	city_spawn(state)
	if state.dev do city_spawn_roads(state)
}

// Plan for the seed, with a log line: tier counts and build time.
city_plan :: proc(seed: u32) -> Plan {
	t := time.tick_now()
	p := plan_build(seed)
	counts: [Tier]int
	for plot in p.buildings do counts[plot.tier] += 1
	log.infof(
		"city: plan %v skyscrapers, %v medium, %v small, %v roads, build %.1f ms",
		counts[.Skyscraper],
		counts[.Medium],
		counts[.Small],
		len(p.roads),
		build_ms(t),
	)
	return p
}

build_ms :: proc(start: time.Tick) -> f64 {
	return time.duration_milliseconds(time.tick_since(start))
}
