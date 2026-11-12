// Host: owns the window, the loop and scene switching. One host per process, so
// its state lives in package globals.
package engine

import "core:fmt"
import "core:log"
import "core:os"
import "gfx"
import "input"
import sdl "vendor:sdl3"

// Number keys bind the first MAX_SCENE_KEYS scenes (1-9, 0); the rest open only
// from the CLI or change_scene.
MAX_SCENE_KEYS :: 10

Config :: struct {
	title:       string,
	width:       int,
	height:      int,
	fullscreen:  bool,
	resizable:   bool, // window can be resized; host follows WINDOW_PIXEL_SIZE_CHANGED
	cursor:      bool, // free system cursor: no relative mouse mode, no grab
	scenes:      []Scene_Entry, // order = number keys 1..9,0
	start:       string,
	after_frame: proc(ctx: ^Context, scene_name: string, dt: f32, user: rawptr), // may call request_quit
	before_exit: proc(ctx: ^Context, scene_name: string, user: rawptr), // after the loop, before teardown
	user:        rawptr,
	fixed_hz:          f32, // Scene.fixed_tick rate; 0 = 60
	max_fixed_updates: int, // steps per frame cap; 0 = 5
}

@(private) host_config: Config
@(private) host_scene: Scene
@(private) fixed_accumulator: f32
@(private) switch_count: int
@(private) quit_action, msaa_action: input.Button_Action
@(private) switch_actions: [MAX_SCENE_KEYS]input.Button_Action
// Input state before the scene registered its own actions; switching rewinds
// to it so scenes do not accumulate dead actions and bindings.
@(private) scene_input_mark: input.Mark
current_scene: int

run :: proc(config: Config) {
	scene, found := scene_lookup(config.scenes, config.start)
	if !found {
		log.errorf("unknown scene %q — expected one of:", config.start)
		for entry in config.scenes do log.errorf("%s", entry.name)
		os.exit(1)
	}
	for entry, index in config.scenes do if entry.name == config.start do current_scene = index
	host_run(config, scene)
}

host_run :: proc(config: Config, scene: Scene) {
	host_config = config
	host_scene = scene
	switch_count = min(len(config.scenes), MAX_SCENE_KEYS)

	ctx: Context
	// Fullscreen skips the compositor (~2 ms floor, 16 ms spikes); --WINDOWED opts out.
	created := context_create(&ctx, config.title, config.width, config.height, config.fullscreen, config.resizable, config.cursor)
	assert(created)

	quit_action = input.button(&ctx.input, "app.quit")
	input.bind_key(&ctx.input, quit_action, .ESCAPE)
	msaa_action = input.button(&ctx.input, "app.msaa")
	input.bind_key(&ctx.input, msaa_action, .M)
	for index in 0 ..< switch_count {
		switch_actions[index] = input.button(&ctx.input, config.scenes[index].name)
		input.bind_key(&ctx.input, switch_actions[index], input.Key(int(input.Key._1) + index))
	}
	transition_create(&ctx.gfx)
	stats_create(&ctx)
	scene_input_mark = input.system_mark(&ctx.input)
	scene_ok := host_scene_create(&ctx, &host_scene)
	assert(scene_ok)

	host_loop(&ctx)

	if config.before_exit != nil do config.before_exit(&ctx, host_scene.name, config.user)
	transition_destroy(&ctx.gfx)
	stats_destroy(&ctx.gfx) // before the device goes: it frees GPU resources
	host_scene_destroy(&ctx, &host_scene)
	context_destroy(&ctx)
}

host_loop :: proc(ctx: ^Context) {
	for ctx.running {
		clock_update(&ctx.clock)
		event: sdl.Event
		for sdl.PollEvent(&event) {
			if !input.register_event(&ctx.input, &event) && event.type == .QUIT do ctx.running = false
			if host_config.resizable && event.type == .WINDOW_PIXEL_SIZE_CHANGED do host_resize(ctx)
			if ctx.event_hook != nil do ctx.event_hook(&event, ctx.event_hook_data)
		}
		input.update(&ctx.input)
		if !ctx.running do break
		host_tick(ctx, ctx.delta)
		free_all(context.temp_allocator)
	}
}

// Window size is in points, the same unit as mouse events (input.mouse_position);
// GetWindowSizeInPixels would mismatch on high-DPI displays.
host_resize :: proc(ctx: ^Context) {
	gfx_ctx := &ctx.gfx
	ok := sdl.GetWindowSize(gfx_ctx.window, &gfx_ctx.window_size.x, &gfx_ctx.window_size.y); assert(ok)
	if gfx_ctx.window_size.x <= 0 || gfx_ctx.window_size.y <= 0 do return // minimized
	gfx.renderer_resize_targets(&gfx_ctx.renderer, u32(gfx_ctx.window_size.x), u32(gfx_ctx.window_size.y))
	gfx.camera_set_aspect(gfx.camera(gfx_ctx), gfx.aspect_ratio(gfx_ctx))
}

host_tick :: proc(ctx: ^Context, delta_time: f32) {
	scene := &host_scene
	if input.pressed(&ctx.input, quit_action) {
		request_quit(ctx)
		return
	}
	if input.pressed(&ctx.input, msaa_action) {
		renderer := &ctx.gfx.renderer
		on := gfx.renderer_set_msaa(renderer, !renderer.msaa_enabled)
		log.infof("MSAA %s", on ? "4x" : (renderer.msaa_supported ? "off" : "unsupported"))
	}
	for index in 0 ..< switch_count {
		if index != current_scene && input.pressed(&ctx.input, switch_actions[index]) {
			change_scene(host_config.scenes[index].name, .Fade, 0.5)
		}
	}
	if transition_tick(ctx, scene, delta_time) do return
	stats_tick(ctx, delta_time, scene.name)
	if scene.fixed_tick != nil {
		hz := host_config.fixed_hz > 0 ? host_config.fixed_hz : 60
		max_steps := host_config.max_fixed_updates > 0 ? host_config.max_fixed_updates : 5
		steps: int
		steps, ctx.blend = fixed_steps(&fixed_accumulator, delta_time, 1 / hz, max_steps)
		for _ in 0 ..< steps do scene.fixed_tick(scene, ctx, 1 / hz)
	}
	scene.tick(scene, ctx, delta_time)

	scene.fps_timer += delta_time
	if scene.fps_timer >= 0.5 {
		scene.fps_timer = 0
		title := fmt.caprintf(
			"Cubes — %s — %.0f FPS — MSAA %s (M)",
			scene.name,
			1 / delta_time,
			ctx.gfx.renderer.msaa_enabled ? "4x" : "off",
			allocator = context.temp_allocator,
		)
		_ = sdl.SetWindowTitle(ctx.gfx.window, title)
	}

	if host_config.after_frame != nil do host_config.after_frame(ctx, scene.name, delta_time, host_config.user)
}

// Tears the running scene down and starts another without restarting the
// device. Runs at the top of a tick, so no frame or pass is open.
host_scene_switch :: proc(ctx: ^Context, scene: ^Scene, index: int) {
	log.infof("switching scene: %s -> %s", host_config.scenes[current_scene].name, host_config.scenes[index].name)
	_ = sdl.WaitForGPUIdle(ctx.gfx.gpu) // the old scene's buffers may still be in flight
	host_scene_destroy(ctx, scene)
	input.system_rewind(&ctx.input, scene_input_mark)
	fixed_accumulator = 0
	gfx.set_present_mode(&ctx.gfx, .IMMEDIATE)

	next, _ := scene_lookup(host_config.scenes, host_config.scenes[index].name)
	scene^ = next
	current_scene = index
	if !host_scene_create(ctx, scene) {
		log.errorf("scene %q failed to create", host_config.scenes[index].name)
		request_quit(ctx)
	}
}

host_scene_create :: proc(ctx: ^Context, scene: ^Scene) -> bool {
	gfx.scope_begin(&ctx.gfx) // every create pairs with exactly one host_scene_destroy, even if create fails
	return scene.create(scene, ctx)
}

host_scene_destroy :: proc(ctx: ^Context, scene: ^Scene) {
	if scene.state != nil {
		scene.destroy(scene, ctx)
		scene.state = nil
	}
	gfx.scope_end(&ctx.gfx) // frees the scene's handle resources not destroyed manually
}

// Single-scene app: start/update procs with a typed app pointer, a World, and the
// host's ESC/quit handling. Used by run_app only.
@(private) App_Run :: struct {
	app:    rawptr,
	start:  proc(app: rawptr, world: ^World),
	update: proc(app: rawptr, world: ^World, dt: f32),
	world:  World,
}

@(private) app_run: App_Run

run_app :: proc(
	app: ^$T,
	start: proc(app: ^T, world: ^World),
	update: proc(app: ^T, world: ^World, dt: f32),
	title := "Odin Engine",
	width := 1280,
	height := 780,
	fullscreen := false,
) {
	app_run = App_Run {
		app    = app,
		start  = transmute(proc(rawptr, ^World))start,
		update = transmute(proc(rawptr, ^World, f32))update,
	}
	app_scene := Scene {
		name    = "app",
		create  = app_create,
		tick    = app_tick,
		destroy = app_destroy,
	}
	host_run(Config{title = title, width = width, height = height, fullscreen = fullscreen}, app_scene)
}

@(private) app_create :: proc(scene: ^Scene, ctx: ^Context) -> bool {
	scene.state = &app_run
	app_run.world = world_create(&ctx.gfx)
	app_run.start(app_run.app, &app_run.world)
	return true
}

@(private) app_tick :: proc(scene: ^Scene, ctx: ^Context, delta_time: f32) {
	run := cast(^App_Run)scene.state
	run.update(run.app, &run.world, delta_time)
	world_update(&run.world, delta_time)
	world_render(&run.world)
}

@(private) app_destroy :: proc(scene: ^Scene, ctx: ^Context) {
	run := cast(^App_Run)scene.state
	world_destroy(&run.world)
}
