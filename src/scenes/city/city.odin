// Whole-city mesh from the plan: every building in one Mesh_Builder, one Raw_Draw. The dev view adds the streets
// as a second Raw_Draw. The night view adds the cars (cars.odin) and the beacons and roof lights (beacons.odin).
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
	camera := parameters.camera_position
	uniforms := shader_parameters.CityVertexUniforms {
		mvp             = parameters.view_projection * parameters.model_transform,
		camera_position = {camera.x, camera.y, camera.z, 1},
		fog             = parameters.fog,
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
	case .Tower:
		return building_tower
	case .Stepped:
		return building_stepped
	case .Slab:
		return building_slab
	case .Twin:
		return building_twin
	case .LShape:
		return building_lshape
	case .Warehouse:
		return building_warehouse
	}
	unreachable()
}

// Each building seeds its own generator from its index, so the mesh does not depend on generation order.
city_build_mesh :: proc(p: ^Plan, seed: u32) -> Mesh_Builder {
	b: Mesh_Builder
	reserve(&b.vertices, len(p.buildings) * 64)
	reserve(&b.indices, len(p.buildings) * 96)
	for i in 0 ..< len(p.buildings) do building_emit(&b, p, seed, i)
	return b
}

// Building i's geometry as the city mesh draws it. Its seeded stream depends only on (seed, i), so a caller that
// replays a single building gets the same walls, clutter and antenna.
building_emit :: proc(b: ^Mesh_Builder, p: ^Plan, seed: u32, i: int) {
	plot := p.buildings[i]
	rng := rng_seed(seed ~ (u32(i + 1) * BUILDING_SEED_MIX))
	rng_u32(&rng) // first output of a near-zero xorshift state is weakly mixed
	origin := Vec3{f32(plot.x) + f32(plot.w) / 2, 0, f32(plot.z) + f32(plot.d) / 2}
	building_proc(plot.kind)(b, &rng, origin, {f32(plot.w), f32(plot.d)}, int(plot.stories))
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

// Dev view: streets on, or the night view with the sky on. Sky and streets are never alive together.
city_set_dev :: proc(state: ^City_State, renderer: ^gfx.Renderer, dev: bool) {
	state.dev = dev
	if dev {
		city_despawn_sky(state)
		city_despawn_lamps(state)
		city_despawn_cars(state)
		city_despawn_beacons(state)
		city_despawn_ground(state)
		city_spawn_roads(state)
		renderer.clear_color = CITY_CLEAR_COLOR
	} else {
		city_despawn_roads(state)
		city_spawn_sky(state)
		city_spawn_lamps(state)
		city_spawn_cars(state)
		city_spawn_beacons(state)
		city_spawn_ground(state)
		renderer.clear_color = CITY_NIGHT_COLOR
	}
	city_apply_effects(state, renderer)
}

// Fog and bloom are night-only: the dev view is an unlit, flat overlay. Both follow their toggles.
// Fog lives on the Environment: apply_environment rewrites renderer.fog from it every world_update.
city_apply_effects :: proc(state: ^City_State, renderer: ^gfx.Renderer) {
	night := !state.dev
	env := engine.actor_props(&state.world, state.env, engine.Environment)
	env.fog = nil
	if night && state.fog_on do env.fog = CITY_FOG
	if night && state.bloom_on {
		gfx.renderer_set_passes(renderer, .Post, []gfx.Render_Pass{gfx.bloom_pass(&state.bloom)})
	} else {
		gfx.renderer_clear_passes(renderer, .Post)
	}
}

// Dev keys [ and ]: step the grade's exposure in EV and log it.
city_set_exposure :: proc(state: ^City_State, ev: f32) {
	env := engine.actor_props(&state.world, state.env, engine.Environment)
	grade := env.grade.?
	grade.exposure += ev
	env.grade = grade
	log.infof("city: exposure %.2f EV", grade.exposure)
}

// Re-plans and re-spawns the city for state.seed, keeping the dev overlay in step.
city_rebuild :: proc(state: ^City_State, renderer: ^gfx.Renderer) {
	city_despawn(state)
	city_despawn_cars(state)
	city_despawn_beacons(state)
	if state.dev {
		city_despawn_roads(state)
	} else {
		city_despawn_lamps(state)
	}
	plan_destroy(&state.plan)
	state.plan = city_plan(state.seed)
	ground_upload_roads(renderer, &state.ground_texture, state.plan.claimed)
	city_spawn(state)
	if state.dev {
		city_spawn_roads(state)
	} else {
		city_spawn_lamps(state)
		city_spawn_cars(state)
		city_spawn_beacons(state)
	}
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
