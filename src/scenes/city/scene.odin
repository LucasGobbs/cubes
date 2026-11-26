// City step 15 (layout): 3072x2048 city, auto-orbit camera for recording, F1 stats. Keys: R re-roll city, G dev view (streets), B bloom, F distance fog, [ ] exposure, O auto-orbit, Y hour +1 (Shift: -1), U day cycle, V weather (clear, rain, storm), WASD/mouse fly, F1 stats, P log stats, Q/E scene.
package city

import engine "../../engine"
import gfx "../../engine/gfx"
import input "../../engine/input"
import shader_parameters "../../shader_parameters"

CITY_CLEAR_COLOR :: [4]f32{0.1, 0.45, 0.1, 1}
CITY_NIGHT_COLOR :: [4]f32{0.002, 0.002, 0.003, 1}
CITY_CAMERA_SPEED :: 300 // units/s (LShift x12, Z x0.1): crossing the 3072-unit city takes ~10 s
CITY_SEED_START :: 1 // fixed start so a run is repeatable; R steps the seed
CITY_DEV_START :: false // night view on start; G toggles the dev view (streets)
// sRGB of linear (0.0015, 0.0018, 0.003): the night fog colour, also the sky's lower band (city_sky.slang params). Stage.fog takes sRGB. Fully fogged beyond the view distance.
CITY_FOG :: engine.Fog{color = {0.01938, 0.023256, 0.03876}, distance = 3200}
CITY_GRADE :: engine.Grade{exposure = 1, contrast = 1, saturation = 1} // ACES tonemap; +1 EV matches the pre-tonemap look; [ and ] step 0.25 EV
CITY_TIME_START :: 22 // hour of day on start: the night view
CITY_WEATHER_START :: 0.5 // 0 clear, 0.5 rain, 1 storm; V cycles them

// Actors of the city, each a struct added with engine.world_add_actor. The state holds pointers; nil when despawned.
City_Draw :: struct {
	using actor: engine.Actor,
	draw:        engine.Raw_Draw,
}

Rain_Emitter :: struct {
	using actor:     engine.Actor,
	using transform: engine.Transform,
	emitter:         engine.Particle_Emitter,
}

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
	ground_draw:     ^City_Draw, // the street ground quad; only alive in the night view
	seed:         u32,
	plan:         Plan,
	city:         ^City_Draw, // the buildings' draw; respawned when R re-rolls the seed
	roads:        ^City_Draw, // the streets' draw; only alive in the dev view
	sky:          ^City_Draw, // the lampshade's draw; only alive in the night view
	lamps:        ^City_Draw, // the streetlights' draw; only alive in the night view
	cars:         ^City_Draw, // the cars' draw; only alive in the night view
	beacons:      ^City_Draw, // the aviation beacons and roof lights' draw; only alive in the night view
	rain:         [2]^Rain_Emitter, // near and far wrap-volume GPU emitters centred on the camera (rain.odin)
	rain_on:      bool,
	toggle_rain:  input.Button_Action,
	road_material: gfx.Material, // unlit blue
	lamp_material: gfx.Material, // streetlight billboards, HDR, additive
	lamp_pipeline: gfx.Pipeline_Handle,
	car_material: gfx.Material, // unlit lamp quads, HDR; the car shader sets the colours
	car_pipeline: gfx.Pipeline_Handle,
	beacon_material: gfx.Material, // beacon billboards, HDR, additive; the shader blinks them from time
	beacon_pipeline: gfx.Pipeline_Handle,
	time:         f32, // seconds, advanced in city_tick; the car shader reads it through user_data
	time_of_day:    f32, // hour 0..24; Y steps it, U runs the cycle. Sky, fog, grade and lights follow (city_apply_day)
	cycle_on:       bool,
	weather:        f32, // 0 clear, 0.5 rain, 1 storm: drives rain density, wet street, fog, exposure and lightning
	exposure_offset: f32, // dev keys [ ] offset in EV, on top of CITY_GRADE and the day terms
	day:            Day_Params, // sky_params(time_of_day), set each frame by city_apply_day
	flash:          f32, // lightning flash 0..1, set each frame by city_apply_day
	toggle_hour:    input.Button_Action,
	shift:          input.Button_Action,
	toggle_cycle:   input.Button_Action,
	toggle_weather: input.Button_Action,
	bloom:        gfx.Bloom,
	dev:          bool,
	regenerate:   bool, // the before-hook regenerates the window and sky textures when set
	reroll:       input.Button_Action,
	toggle_dev:   input.Button_Action,
	toggle_bloom: input.Button_Action,
	toggle_fog:   input.Button_Action,
	exposure_down: input.Button_Action,
	exposure_up:  input.Button_Action,
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
	state.world.stage = engine.Stage{grade = CITY_GRADE}
	engine.camera_fly(ctx, {1536, 420, 2500}, {1536, 60, 1024}, CITY_CAMERA_SPEED)
	orbit_set(&state.orbit, ctx, CITY_ORBIT_START)

	state.window = window_texture_create(&ctx.gfx)
	state.sampler = gfx.sampler_create(&ctx.gfx, WINDOW_SAMPLER)
	state.pipeline = city_pipeline_create(&ctx.gfx, state)
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
	state.sky_pipeline = sky_pipeline_create(&ctx.gfx, state)
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
	state.ground_pipeline = ground_pipeline_create(&ctx.gfx, state)
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
	state.lamp_pipeline = lights_pipeline_create(&ctx.gfx, state)
	state.lamp_material = gfx.material_make(state.lamp_pipeline)
	// Glow: threshold 0.45 with 0.2 soft knee; levels half/quarter/eighth weighted 1.4/1.0/0.7, blur 3/6/8 texels; 0.012 black floor.
	state.bloom = gfx.bloom_create_multi(&ctx.gfx, 0.45, 0.2, 1.0, 0.012, 3, {3, 6, 8}, {1.4, 1.0, 0.7})
	state.car_pipeline = cars_pipeline_create(&ctx.gfx, state)
	state.car_material = gfx.material_make(state.car_pipeline)
	state.beacon_pipeline = beacons_pipeline_create(&ctx.gfx, state)
	state.beacon_material = gfx.material_make(state.beacon_pipeline)
	state.bloom_on = true
	state.fog_on = true
	state.time_of_day = CITY_TIME_START
	state.weather = CITY_WEATHER_START
	rain_spawn(state)
	state.rain_on = true
	rain_set_intensity(state, state.weather)
	ground_set_wetness(state, state.weather)

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
	state.toggle_rain = input.button(&ctx.input, "city.rain", .T, "Toggle rain")
	state.toggle_orbit = input.button(&ctx.input, "city.orbit", .O, "Toggle auto-orbit camera")
	state.exposure_down = input.button(&ctx.input, "city.exposure_down", .LEFTBRACKET, "Exposure down 0.25 EV")
	state.exposure_up = input.button(&ctx.input, "city.exposure_up", .RIGHTBRACKET, "Exposure up 0.25 EV")
	state.toggle_hour = input.button(&ctx.input, "city.hour", .Y, "Time of day +1 h (Shift: -1 h)")
	state.shift = input.button(&ctx.input, "city.shift", .LSHIFT, "Shift: reverse the hour step")
	state.toggle_cycle = input.button(&ctx.input, "city.cycle", .U, "Toggle the day cycle")
	state.toggle_weather = input.button(&ctx.input, "city.weather", .V, "Cycle weather: clear, rain, storm")
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
	if input.pressed(&ctx.input, state.exposure_down) do city_set_exposure(state, -0.25)
	if input.pressed(&ctx.input, state.exposure_up) do city_set_exposure(state, 0.25)
	if input.pressed(&ctx.input, state.toggle_hour) {
		step: f32 = 1
		if input.down(&ctx.input, state.shift) do step = -1
		state.time_of_day = wrap_hour(state.time_of_day + step)
	}
	if input.pressed(&ctx.input, state.toggle_cycle) do state.cycle_on = !state.cycle_on
	if input.pressed(&ctx.input, state.toggle_weather) {
		if state.weather == 0 do state.weather = 0.5
		else if state.weather == 0.5 do state.weather = 1
		else do state.weather = 0
		rain_set_intensity(state, state.weather)
		ground_set_wetness(state, state.weather)
	}
	if input.pressed(&ctx.input, state.toggle_orbit) do orbit_set(&state.orbit, ctx, !state.orbit.on)
	orbit_update(&state.orbit, ctx, delta_time)
	if input.pressed(&ctx.input, state.toggle_rain) do rain_set(state, !state.rain_on)
	state.time += delta_time
	if state.cycle_on do state.time_of_day = day_cycle_advance(state.time_of_day, delta_time)
	city_apply_day(state)
	engine.world_update(&state.world, delta_time)
	engine.world_render(&state.world, ctx.blend)
}

city_destroy :: proc(demo: ^engine.Scene, ctx: ^engine.Context) {
	state := cast(^City_State)demo.state
	gfx.renderer_remove_scene_hook(&ctx.gfx.renderer, state)
	engine.world_destroy(&state.world)
	gfx.renderer_clear_passes(&ctx.gfx.renderer, .Post)
	gfx.bloom_destroy(&ctx.gfx, &state.bloom)
	plan_destroy(&state.plan)
	gfx.material_destroy(&state.material)
	gfx.material_destroy(&state.road_material)
	gfx.material_destroy(&state.lamp_material)
	gfx.material_destroy(&state.car_material)
	gfx.material_destroy(&state.beacon_material)
	gfx.material_destroy(&state.sky_material)
	gfx.material_destroy(&state.ground_material)
	gfx.pipeline_destroy(&ctx.gfx, state.pipeline)
	gfx.pipeline_destroy(&ctx.gfx, state.sky_pipeline)
	gfx.pipeline_destroy(&ctx.gfx, state.ground_pipeline)
	gfx.pipeline_destroy(&ctx.gfx, state.car_pipeline)
	gfx.pipeline_destroy(&ctx.gfx, state.lamp_pipeline)
	gfx.pipeline_destroy(&ctx.gfx, state.beacon_pipeline)
	window_texture_destroy(&ctx.gfx, &state.window)
	sky_texture_destroy(&ctx.gfx, &state.sky_texture)
	gfx.sampler_destroy(&ctx.gfx, state.sampler)
	gfx.sampler_destroy(&ctx.gfx, state.sky_sampler)
	gfx.sampler_destroy(&ctx.gfx, state.ground_sampler)
	ground_texture_destroy(&ctx.gfx, &state.ground_texture)
	free(state)
}
