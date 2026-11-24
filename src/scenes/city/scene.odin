// City step 8: night sky (compute gradient, stars and clouds) on a camera-following lampshade. Dev view draws streets.
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
	seed:         u32,
	plan:         Plan,
	city:         engine.Actor_Id, // the buildings' Raw_Draw; respawned when R re-rolls the seed
	roads:        engine.Actor_Id, // the streets' Raw_Draw; only alive in the dev view
	sky:          engine.Actor_Id, // the lampshade's Raw_Draw; only alive in the night view
	road_material: gfx.Material, // unlit blue
	dev:          bool,
	regenerate:   bool, // the before-hook regenerates the window and sky textures when set
	reroll:       input.Button_Action,
	toggle_dev:   input.Button_Action,
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
	state.road_material = gfx.material_make(gfx.builtin_material_pipeline(&ctx.gfx, .Unlit))
	gfx.set_unlit_color(&state.road_material, ROAD_COLOR)

	state.seed = CITY_SEED_START
	state.regenerate = true
	state.plan = city_plan(state.seed)
	city_spawn(state)
	city_set_dev(state, &ctx.gfx.renderer, CITY_DEV_START)

	state.reroll = input.button(&ctx.input, "city.reroll", .R, "Re-roll city")
	state.toggle_dev = input.button(&ctx.input, "city.dev", .G, "Toggle dev view (streets)")
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
		city_rebuild(state)
	}
	if input.pressed(&ctx.input, state.toggle_dev) do city_set_dev(state, &ctx.gfx.renderer, !state.dev)
	engine.world_update(&state.world, delta_time)
	engine.world_render(&state.world, ctx.blend)
}

city_destroy :: proc(demo: ^engine.Scene, ctx: ^engine.Context) {
	state := cast(^City_State)demo.state
	gfx.renderer_remove_scene_hook(&ctx.gfx.renderer, state)
	engine.world_destroy(&state.world)
	plan_destroy(&state.plan)
	gfx.material_destroy(&state.material)
	gfx.material_destroy(&state.road_material)
	gfx.material_destroy(&state.sky_material)
	gfx.pipeline_destroy(&ctx.gfx, state.pipeline)
	gfx.pipeline_destroy(&ctx.gfx, state.sky_pipeline)
	window_texture_destroy(&ctx.gfx, &state.window)
	sky_texture_destroy(&ctx.gfx, &state.sky_texture)
	gfx.sampler_destroy(&ctx.gfx, state.sampler)
	gfx.sampler_destroy(&ctx.gfx, state.sky_sampler)
	free(state)
}
