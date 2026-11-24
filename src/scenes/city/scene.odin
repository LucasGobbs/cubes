// City step 2: a window atlas from a compute pass, shown on a row of cubes and a poster.
package city

import engine "../../engine"
import shader_parameters "../../shader_parameters"
import gfx "../../engine/gfx"
import input "../../engine/input"

CITY_CLEAR_COLOR :: [4]f32{0.1, 0.45, 0.1, 1}
CITY_CAMERA_SPEED :: 100 // units/s: crossing the 1024-unit city takes ~10 s
CITY_SEED_START :: 1 // fixed start so a run is repeatable; R steps the seed

City_State :: struct {
	world:      engine.World,
	pipeline:   gfx.Pipeline_Handle,
	material:   gfx.Material,
	window:     Window_Texture,
	sampler:    gfx.Sampler_Handle,
	seed:       u32,
	shape:      u32, // window shape 0..7, T steps it, R keeps it
	regenerate: bool, // the before-hook regenerates the atlas when set
	reroll:     input.Button_Action,
	next_shape: input.Button_Action,
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
	ctx.gfx.renderer.clear_color = CITY_CLEAR_COLOR
	engine.camera_fly(ctx, {0, 56, 90}, {0, 56, -30}, CITY_CAMERA_SPEED)

	state.window = window_texture_create(&ctx.gfx)
	state.sampler = gfx.sampler_create(&ctx.gfx, WINDOW_SAMPLER)
	state.pipeline = gallery_pipeline_create(&ctx.gfx)
	state.material = gfx.material_make(state.pipeline)
	gfx.material_bind_texture(
		&state.material,
		shader_parameters.CITY_FRAGMENT_WINDOW_TEXTURE,
		shader_parameters.CITY_FRAGMENT_WINDOW_SAMPLER,
		state.window.texture,
		state.sampler,
	)
	engine.spawn(&state.world, engine.Raw_Draw{mesh = gallery_mesh(), material = &state.material})

	state.seed = CITY_SEED_START
	state.shape = window_shape_for_seed(state.seed)
	state.regenerate = true
	state.reroll = input.button(&ctx.input, "city.reroll", .R, "Re-roll city")
	state.next_shape = input.button(&ctx.input, "city.shape", .T, "Next window shape")
	gfx.renderer_add_scene_hook(&ctx.gfx.renderer, gfx.Scene_Hook{name = "city_windows", before = city_before, user = state})
	return true
}

// Scene before-hook: compute runs outside any pass with the frame open, before the scene pass samples the atlas.
city_before :: proc(renderer: ^gfx.Renderer, user: rawptr) {
	state := cast(^City_State)user
	if !state.regenerate do return
	state.regenerate = false
	window_texture_generate(renderer.gfx_ctx, &state.window, state.seed, state.shape)
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
	}
	if input.pressed(&ctx.input, state.next_shape) {
		state.shape = (state.shape + 1) % WINDOW_SHAPE_COUNT
		state.regenerate = true
	}
	engine.world_update(&state.world, delta_time)
	engine.world_render(&state.world, ctx.blend)
}

city_destroy :: proc(demo: ^engine.Scene, ctx: ^engine.Context) {
	state := cast(^City_State)demo.state
	gfx.renderer_remove_scene_hook(&ctx.gfx.renderer, state)
	engine.world_destroy(&state.world)
	gfx.material_destroy(&state.material)
	gfx.pipeline_destroy(&ctx.gfx, state.pipeline)
	window_texture_destroy(&ctx.gfx, &state.window)
	gfx.sampler_destroy(&ctx.gfx, state.sampler)
	free(state)
}
