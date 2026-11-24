// City step 12 (polish): auto-orbit camera for recording, F1 stats. Keys: R re-roll city, G dev view (streets), B bloom, F distance fog, O auto-orbit, WASD/mouse fly, F1 stats, P log stats, Q/E scene.
package city

import engine "../../engine"
import gfx "../../engine/gfx"
import input "../../engine/input"
import shader_parameters "../../shader_parameters"

CITY_CLEAR_COLOR :: [4]f32{0.1, 0.45, 0.1, 1}
CITY_NIGHT_COLOR :: [4]f32{0.01, 0.01, 0.02, 1}
CITY_CAMERA_SPEED :: 300 // units/s: crossing the 1024-unit city takes ~3.5 s
CITY_SEED_START :: 1 // fixed start so a run is repeatable; R steps the seed
CITY_DEV_START :: false // night view on start; G toggles the dev view (streets)
CITY_FOG :: [4]f32{0.10, 0.035, 0.04, 1600} // linear rgb haze, a = view distance; fully fogged beyond it
CITY_BLOOM_THRESHOLD :: 0.9 // lamps are tinted above this (LAMP_EMISSION), so they bloom and the lit windows barely do
CITY_BLOOM_INTENSITY :: 0.5
CITY_BLOOM_RADIUS :: 6

City_State :: struct {
	world:        engine.World,
	pipeline:     gfx.Pipeline_Handle,
	material:     gfx.Material,
	window:       Window_Texture,
	sampler:      gfx.Sampler_Handle,
	sky_texture:  Sky_Texture,
	sky_sampler:  gfx.Sampler_Handle,
	sky_pipeline: gfx.Pipeline_Handle,
	sky_material: gfx.Material,
	ground_texture:  Ground_Texture,
	ground_sampler:  gfx.Sampler_Handle,
	ground_pipeline: gfx.Pipeline_Handle,
	ground_material: gfx.Material,
	ground_draw:     engine.Actor_Id, // the street ground quad; only alive in the night view
	seed:         u32,
	plan:         Plan,
	city:         engine.Actor_Id, // the buildings' Raw_Draw; respawned when R re-rolls the seed
	roads:        engine.Actor_Id, // the streets' Raw_Draw; only alive in the dev view
	sky:          engine.Actor_Id, // the lampshade's Raw_Draw; only alive in the night view
	lamps:        engine.Actor_Id, // the streetlights' Raw_Draw; only alive in the night view
	cars:         engine.Actor_Id, // the cars' Raw_Draw; only alive in the night view
	road_material: gfx.Material, // unlit blue
	lamp_material: gfx.Material, // emissive sodium orange
	car_material: gfx.Material, // unlit lamp quads, HDR; the car shader sets the colours
	car_pipeline: gfx.Pipeline_Handle,
	time:         f32, // seconds, advanced in city_tick; the car shader reads it through user_data
	bloom:        gfx.Bloom,
	dev:          bool,
	regenerate:   bool, // the before-hook regenerates the window and sky textures when set
	reroll:       input.Button_Action,
	toggle_dev:   input.Button_Action,
	toggle_bloom: input.Button_Action,
	toggle_fog:   input.Button_Action,
	bloom_on:     bool,
	fog_on:       bool,
	orbit:        City_Orbit,
	toggle_orbit: input.Button_Action,
}

city_scene :: proc() -> engine.Scene {
	return {
		name = "City",
		create = city_create,
		tick = city_tick,
		destroy = city_destroy,
	}
}

city_create :: proc(demo: ^engine.Scene, ctx: ^engine.Context) -> bool {
	state := new(City_State)
	demo.state = state
	state.world = engine.world_create(&ctx.gfx)
	engine.camera_fly(ctx, {512, 220, 1250}, {512, 90, 300}, CITY_CAMERA_SPEED)
	orbit_set(&state.orbit, ctx, CITY_ORBIT_START)

	state.window = window_texture_create(&ctx.gfx)
	state.sampler = gfx.sampler_create(&ctx.gfx, WINDOW_SAMPLER)
	state.pipeline = city_pipeline_create(&ctx.gfx)
	state.material = gfx.material_make(state.pipeline)
	gfx.material_bind_texture(
		&state.material,
		shader_parameters.CITY_FRAGMENT_WINDOW_TEXTURE,
		shader_parameters.CITY_FRAGMENT_WINDOW_SAMPLER,
		state.window.texture,
		state.sampler,
	)
	state.sky_texture = sky_texture_create(&ctx.gfx)
	state.sky_sampler = gfx.sampler_create(&ctx.gfx, SKY_SAMPLER)
	state.sky_pipeline = sky_pipeline_create(&ctx.gfx)
	state.sky_material = gfx.material_make(state.sky_pipeline)
	gfx.material_bind_texture(
		&state.sky_material,
		shader_parameters.CITY_SKY_FRAGMENT_SKY_TEXTURE,
		shader_parameters.CITY_SKY_FRAGMENT_SKY_SAMPLER,
		state.sky_texture.texture,
		state.sky_sampler,
	)
	state.ground_texture = ground_texture_create(&ctx.gfx)
	state.ground_sampler = gfx.sampler_create(&ctx.gfx, GROUND_SAMPLER)
	state.ground_pipeline = ground_pipeline_create(&ctx.gfx)
	state.ground_material = gfx.material_make(state.ground_pipeline)
	gfx.material_bind_texture(
		&state.ground_material,
		shader_parameters.CITY_GROUND_FRAGMENT_GROUND_TEXTURE,
		shader_parameters.CITY_GROUND_FRAGMENT_GROUND_SAMPLER,
		state.ground_texture.texture,
		state.ground_sampler,
	)
	state.road_material = gfx.material_make(gfx.builtin_material_pipeline(&ctx.gfx, .Unlit))
	gfx.set_unlit_color(&state.road_material, ROAD_COLOR)
	state.lamp_material = gfx.material_make(gfx.builtin_material_pipeline(&ctx.gfx, .Emissive))
	gfx.set_emissive_color(&state.lamp_material, LAMP_TINT, LAMP_EMISSION)
	state.car_pipeline = cars_pipeline_create(&ctx.gfx, state)
	state.car_material = gfx.material_make(state.car_pipeline)
	state.bloom = gfx.bloom_create(&ctx.gfx, CITY_BLOOM_THRESHOLD, CITY_BLOOM_INTENSITY, CITY_BLOOM_RADIUS)
	state.bloom_on = true
	state.fog_on = true

	state.seed = CITY_SEED_START
	state.regenerate = true
	state.plan = city_plan(state.seed)
	ground_upload_roads(&ctx.gfx.renderer, &state.ground_texture, state.plan.claimed)
	city_spawn(state)
	city_set_dev(state, &ctx.gfx.renderer, CITY_DEV_START)

	state.reroll = input.button(&ctx.input, "city.reroll", .R, "Re-roll city")
	state.toggle_dev = input.button(&ctx.input, "city.dev", .G, "Toggle dev view (streets)")
	state.toggle_bloom = input.button(&ctx.input, "city.bloom", .B, "Toggle bloom")
	state.toggle_fog = input.button(&ctx.input, "city.fog", .F, "Toggle distance fog")
	state.toggle_orbit = input.button(&ctx.input, "city.orbit", .O, "Toggle auto-orbit camera")
	gfx.renderer_add_scene_hook(&ctx.gfx.renderer, gfx.Scene_Hook{name = "city_windows", before = city_before, user = state})
	return true
}

// Scene before-hook: compute runs outside any pass with the frame open, before the scene pass samples the textures.
city_before :: proc(renderer: ^gfx.Renderer, user: rawptr) {
	state := cast(^City_State)user
	if !state.regenerate do return
	state.regenerate = false
	window_texture_generate(renderer.gfx_ctx, &state.window, state.seed)
	sky_texture_generate(renderer.gfx_ctx, &state.sky_texture, state.seed)
	ground_texture_generate(renderer.gfx_ctx, &state.ground_texture)
}

city_tick :: proc(demo: ^engine.Scene, ctx: ^engine.Context, delta_time: f32) {
	state := cast(^City_State)demo.state
	if input.pressed(&ctx.input, state.reroll) {
		// xorshift32: never zero for a non-zero seed, so the sequence never sticks
		s := state.seed
		s ~= s << 13
		s ~= s >> 17
		s ~= s << 5
		state.seed = s
		state.regenerate = true
		city_rebuild(state, &ctx.gfx.renderer)
	}
	if input.pressed(&ctx.input, state.toggle_dev) do city_set_dev(state, &ctx.gfx.renderer, !state.dev)
	if input.pressed(&ctx.input, state.toggle_bloom) {
		state.bloom_on = !state.bloom_on
		city_apply_effects(state, &ctx.gfx.renderer)
	}
	if input.pressed(&ctx.input, state.toggle_fog) {
		state.fog_on = !state.fog_on
		city_apply_effects(state, &ctx.gfx.renderer)
	}
	if input.pressed(&ctx.input, state.toggle_orbit) do orbit_set(&state.orbit, ctx, !state.orbit.on)
	orbit_update(&state.orbit, ctx, delta_time)
	state.time += delta_time
	engine.world_update(&state.world, delta_time)
	engine.world_render(&state.world, ctx.blend)
}

city_destroy :: proc(demo: ^engine.Scene, ctx: ^engine.Context) {
	state := cast(^City_State)demo.state
	gfx.renderer_remove_scene_hook(&ctx.gfx.renderer, state)
	engine.world_destroy(&state.world)
	gfx.renderer_clear_passes(&ctx.gfx.renderer, .Post)
	gfx.compute_pipeline_destroy(&ctx.gfx, state.bloom.prefilter)
	gfx.compute_pipeline_destroy(&ctx.gfx, state.bloom.blur)
	gfx.compute_pipeline_destroy(&ctx.gfx, state.bloom.composite)
	plan_destroy(&state.plan)
	gfx.material_destroy(&state.material)
	gfx.material_destroy(&state.road_material)
	gfx.material_destroy(&state.lamp_material)
	gfx.material_destroy(&state.car_material)
	gfx.material_destroy(&state.sky_material)
	gfx.material_destroy(&state.ground_material)
	gfx.pipeline_destroy(&ctx.gfx, state.pipeline)
	gfx.pipeline_destroy(&ctx.gfx, state.sky_pipeline)
	gfx.pipeline_destroy(&ctx.gfx, state.ground_pipeline)
	gfx.pipeline_destroy(&ctx.gfx, state.car_pipeline)
	window_texture_destroy(&ctx.gfx, &state.window)
	sky_texture_destroy(&ctx.gfx, &state.sky_texture)
	gfx.sampler_destroy(&ctx.gfx, state.sampler)
	gfx.sampler_destroy(&ctx.gfx, state.sky_sampler)
	gfx.sampler_destroy(&ctx.gfx, state.ground_sampler)
	ground_texture_destroy(&ctx.gfx, &state.ground_texture)
	free(state)
}
