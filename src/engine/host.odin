// Host: owns the window, the loop and scene switching. One host per process, so
// its state lives in package globals.
package engine

import "core:fmt"
import "core:log"
import "core:os"
import "gfx"
import "input"
import "jobs"
import sdl "vendor:sdl3"

// Number keys pick a scene group (1-9, 0) in order of first appearance; the rest
// of the groups open only from the CLI or change_scene.
MAX_GROUP_KEYS :: 10

Config :: struct {
	title:       string,
	width:       int,
	height:      int,
	fullscreen:  bool,
	resizable:   bool, // window can be resized; host follows WINDOW_PIXEL_SIZE_CHANGED
	display:     int, // 1-based monitor number for the window; 0 = primary, past the last monitor = primary
	cursor:      bool, // free system cursor: no relative mouse mode, no grab
	scenes:      []Scene_Entry, // grouped by Scene_Entry.group; groups in order of first appearance
	start:       string,
	after_frame: proc(ctx: ^Context, scene_name: string, dt: f32, user: rawptr), // may call request_quit
	before_exit: proc(ctx: ^Context, scene_name: string, user: rawptr), // after the loop, before teardown
	user:        rawptr,
	// Drawn while a scene loads behind the covered transition: called every frame inside the
	// open frame (extract time), with the load fraction 0..1. nil = a progress bar in the overlay.
	loading_screen: proc(ctx: ^Context, progress: f32, user: rawptr),
	fixed_hz:          f32, // Scene.fixed_tick rate; 0 = 30
	max_fixed_updates: int, // steps per frame cap; 0 = 5
	fixed_dt:          f32,  // > 0: every frame advances the clock by this many seconds (offline video); 0 = wall clock
	readback:          bool, // keep each frame's pixels for gfx.readback_frame
}

@(private) host_config: Config
@(private) host_scene: Scene
@(private) fixed_accumulator: f32
@(private) quit_action, msaa_action, reload_action: input.Button_Action
@(private) shift_action, pop_action: input.Button_Action // dev: Shift+number pushes, Backspace pops
@(private) preload: ^Load_Context // preload_scene: the single in-flight/finished preload
@(private) dropped_loads: [dynamic]^Load_Context // replaced preloads finishing in the background
@(private) group_actions: [MAX_GROUP_KEYS]input.Button_Action
@(private) group_labels: [MAX_GROUP_KEYS]string // owned: the group actions' descriptions
@(private) scene_prev_action, scene_next_action: input.Button_Action // Q/E within the current group
@(private) host_groups: Scene_Groups
@(private) group_count: int
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
	host_groups = scene_groups_build(config.scenes)
	group_count = min(len(host_groups.names), MAX_GROUP_KEYS)

	ctx: Context
	// Fullscreen skips the compositor (~2 ms floor, 16 ms spikes); --WINDOWED opts out.
	created := context_create(&ctx, config.title, config.width, config.height, config.fullscreen, config.resizable, config.cursor, config.display)
	assert(created)
	jobs.init(&ctx.jobs)
	ctx.gfx.renderer.jobs = &ctx.jobs
	ctx.clock.fixed_dt = config.fixed_dt
	ctx.gfx.renderer.readback.enabled = config.readback

	quit_action = input.button(&ctx.input, "app.quit", .ESCAPE, "Quit")
	msaa_action = input.button(&ctx.input, "app.msaa", .M, "Toggle MSAA")
	reload_action = input.button(&ctx.input, "app.reload_scripts", .F5, "Reload Lua scripts")
	shift_action = input.button(&ctx.input, "app.push_modifier", .LSHIFT, "Hold with a scene number to push it")
	input.bind_key(&ctx.input, shift_action, .RSHIFT)
	pop_action = input.button(&ctx.input, "app.pop", .BACKSPACE, "Pop scene")
	for g in 0 ..< group_count {
		group_labels[g] = fmt.aprintf("%s (%d)", host_groups.names[g], len(host_groups.members[g]))
		key := input.Key(int(input.Key._1) + g)
		group_actions[g] = input.button(&ctx.input, fmt.tprintf("app.group.%s", host_groups.names[g]), key, group_labels[g])
	}
	scene_prev_action = input.button(&ctx.input, "app.scene_prev", .Q, "Previous scene in group")
	scene_next_action = input.button(&ctx.input, "app.scene_next", .E, "Next scene in group")
	transition_create(&ctx.gfx)
	stats_create(&ctx)
	scene_title_create(&ctx.gfx)
	scene_input_mark = input.system_mark(&ctx.input)
	if host_scene.load != nil {
		// Startup has no transition to hide the wait: load synchronously.
		loaded, ok := load_finish(load_start(&ctx.jobs, host_scene, config.start))
		assert(ok, "start scene failed to load")
		host_scene = loaded
	}
	scene_ok := host_scene_create(&ctx, &host_scene)
	assert(scene_ok)
	host_scene_shown(current_scene)

	host_loop(&ctx)

	if config.before_exit != nil do config.before_exit(&ctx, host_scene.name, config.user)
	transition_destroy(&ctx.gfx)
	scene_title_destroy(&ctx.gfx)
	stats_destroy(&ctx.gfx) // before the device goes: it frees GPU resources
	host_scene_destroy(&ctx, &host_scene)
	host_stack_destroy(&ctx)
	host_loads_destroy()
	jobs.destroy(&ctx.jobs) // before the device goes
	context_destroy(&ctx)
	for g in 0 ..< group_count do delete(group_labels[g])
	scene_groups_destroy(&host_groups)
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
	if input.pressed(&ctx.input, reload_action) do script_reload_all()
	shift := input.down(&ctx.input, shift_action)
	for g in 0 ..< group_count {
		if !input.pressed(&ctx.input, group_actions[g]) do continue
		// shortcut: transition picked by group index, cycles through the grid ones
		transitions := [?]Scene_Transition{.Dots, .Dots_Wave, .Squares, .Circle, .Diamond, .Blinds}
		transition := transitions[g % len(transitions)]
		target := host_groups.last[g]
		if shift do push_scene(host_config.scenes[target].name, .Keep, transition, 0.8)
		else if host_groups.group_of[current_scene] != g do change_scene(host_config.scenes[target].name, transition, 0.8)
	}
	if input.pressed(&ctx.input, scene_prev_action) do host_step_scene(false)
	if input.pressed(&ctx.input, scene_next_action) do host_step_scene(true)
	if input.pressed(&ctx.input, pop_action) do pop_scene(.Dots, 0.8)
	host_loads_tick(ctx)
	camera_update(ctx, delta_time)
	if transition_tick(ctx, scene, delta_time) do return
	scene_title_tick(&ctx.gfx, delta_time, host_corner_tag())
	stats_tick(ctx, delta_time, scene.name)
	if scene.fixed_tick != nil {
		hz := host_config.fixed_hz > 0 ? host_config.fixed_hz : 30
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

// Q/E: the neighbouring scene of the current group, wrapping. A single-scene group stays put.
host_step_scene :: proc(forward: bool) {
	group := host_groups.group_of[current_scene]
	members := host_groups.members[group]
	if len(members) < 2 do return
	position := host_groups.position[current_scene]
	next := group_next(position, len(members)) if forward else group_prev(position, len(members))
	change_scene(host_config.scenes[members[next]].name)
}

// Corner tag: the current group and position; empty for single-scene groups.
host_corner_tag :: proc() -> string {
	group := host_groups.group_of[current_scene]
	count := len(host_groups.members[group])
	if count < 2 do return ""
	return fmt.tprintf("%s %d/%d  Q/E", host_groups.names[group], host_groups.position[current_scene] + 1, count)
}

// Every visible-scene change (change, push, pop) ends here: records the scene for its
// group and shows its title.
host_scene_shown :: proc(index: int) {
	scene_groups_visit(&host_groups, index)
	scene_title_show(host_config.scenes[index].name)
}

// preload_scene: starts the named scene's load now. One preload at a time; a replaced one finishes
// in the background and frees its state (see load_discard).
host_preload :: proc(ctx: ^Context, name: string) {
	if preload != nil && preload.name == name do return
	scene, found := scene_lookup(host_config.scenes, name)
	if !found {
		log.errorf("preload_scene: unknown scene %q", name)
		return
	}
	if scene.load == nil do return // nothing to do ahead of time
	if preload != nil do append(&dropped_loads, preload)
	preload = load_start(&ctx.jobs, scene, name)
}

// The preload for `name`, handed over to the caller; nil when there is none.
host_take_preload :: proc(name: string) -> ^Load_Context {
	if preload == nil || preload.name != name do return nil
	lc := preload
	preload = nil
	return lc
}

host_loads_tick :: proc(ctx: ^Context) {
	if name, ok := take_preload_request(); ok do host_preload(ctx, name)
	for i := len(dropped_loads) - 1; i >= 0; i -= 1 {
		if !jobs.done(&dropped_loads[i].group) do continue
		load_discard(dropped_loads[i])
		unordered_remove(&dropped_loads, i)
	}
}

// At exit: wait for and free every load nobody consumed.
host_loads_destroy :: proc() {
	if preload != nil do load_discard(preload)
	preload = nil
	for lc in dropped_loads do load_discard(lc)
	delete(dropped_loads)
	if transition.lc != nil do load_discard(transition.lc)
	transition.lc = nil
}

host_scene_create :: proc(ctx: ^Context, scene: ^Scene) -> bool {
	gfx.scope_begin(&ctx.gfx) // every create pairs with exactly one host_scene_destroy, even if create fails
	ctx.camera = nil
	ctx.camera_keys = nil
	// Default view and targets reset; the JSON camera overrides the default, and a
	// camera_* call in create overrides both.
	start := Camera_Start{position = {0, 0, 3}}
	if json, ok := scene.start_camera.?; ok do start = json
	gfx.camera_reset(&ctx.gfx, start.position, start.look_at)
	return scene.create(scene, ctx)
}

host_scene_destroy :: proc(ctx: ^Context, scene: ^Scene) {
	if scene.state != nil {
		scene.destroy(scene, ctx)
		scene.state = nil
	}
	ctx.camera = nil
	ctx.camera_keys = nil
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
	world_render(&run.world, ctx.blend)
}

@(private) app_destroy :: proc(scene: ^Scene, ctx: ^Context) {
	run := cast(^App_Run)scene.state
	world_destroy(&run.world)
}
