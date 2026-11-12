package engine

import input "input"
import gfx "gfx"

// Owns the window, the GPU device and the World. Blocks until the window closes
// or ESC is pressed. start runs once before the first frame; update runs every
// frame before world_update and world_render.
run :: proc(
	app: ^$T,
	start: proc(app: ^T, world: ^World),
	update: proc(app: ^T, world: ^World, dt: f32),
	title := "Odin Engine",
	width := 1280,
	height := 780,
	fullscreen := false,
) {
	// gfx callbacks take rawptr, so the user procs are stored type-erased.
	// Only the pointer type differs; the calling convention is identical.
	state := Run_State {
		app    = rawptr(app),
		start  = transmute(proc(rawptr, ^World))start,
		update = transmute(proc(rawptr, ^World, f32))update,
	}
	dev: gfx.Device
	created := gfx.create(&dev, rawptr(&state), run_create, title, width, height, fullscreen)
	assert(created)
	defer gfx.destroy(&dev, rawptr(&state), run_destroy)
	gfx.gfx_update(&dev, rawptr(&state), run_tick)
}

@(private = "file")
Run_State :: struct {
	app:    rawptr,
	start:  proc(rawptr, ^World),
	update: proc(rawptr, ^World, f32),
	world:  World,
	quit:   input.Button_Action,
}

@(private = "file")
run_create :: proc(dev: ^gfx.Device, raw_state: rawptr) -> bool {
	state := (^Run_State)(raw_state)
	inputs := gfx.gfx_input(dev)
	state.quit = input.button(inputs, "app.quit")
	input.bind_key(inputs, state.quit, .ESCAPE)
	state.world = world_create(dev)
	state.start(state.app, &state.world)
	return true
}

@(private = "file")
run_tick :: proc(dev: ^gfx.Device, delta_time: f32, raw_state: rawptr) {
	state := (^Run_State)(raw_state)
	if input.pressed(gfx.gfx_input(dev), state.quit) {
		gfx.gfx_request_quit(dev)
		return
	}
	state.update(state.app, &state.world, delta_time)
	world_update(&state.world, delta_time)
	world_render(&state.world)
}

@(private = "file")
run_destroy :: proc(dev: ^gfx.Device, raw_state: rawptr) {
	state := (^Run_State)(raw_state)
	world_destroy(&state.world)
}
