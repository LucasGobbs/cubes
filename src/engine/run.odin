package engine

import glove "../glove"
import gbbfx "../gbbfx"

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
	// gbbfx callbacks take rawptr, so the user procs are stored type-erased.
	// Only the pointer type differs; the calling convention is identical.
	state := Run_State {
		app    = rawptr(app),
		start  = transmute(proc(rawptr, ^World))start,
		update = transmute(proc(rawptr, ^World, f32))update,
	}
	gfx: gbbfx.Gfx
	created := gbbfx.create(&gfx, rawptr(&state), run_create, title, width, height, fullscreen)
	assert(created)
	defer gbbfx.gfx_destroy(&gfx, rawptr(&state), run_destroy)
	gbbfx.gfx_update(&gfx, rawptr(&state), run_tick)
}

@(private = "file")
Run_State :: struct {
	app:    rawptr,
	start:  proc(rawptr, ^World),
	update: proc(rawptr, ^World, f32),
	world:  World,
	quit:   glove.Button_Action,
}

@(private = "file")
run_create :: proc(gfx: ^gbbfx.Gfx, raw_state: rawptr) -> bool {
	state := (^Run_State)(raw_state)
	inputs := gbbfx.gfx_input(gfx)
	state.quit = glove.add_button(inputs, "app.quit")
	glove.bind_key(inputs, state.quit, .ESCAPE)
	state.world = world_create(gfx)
	state.start(state.app, &state.world)
	return true
}

@(private = "file")
run_tick :: proc(gfx: ^gbbfx.Gfx, delta_time: f32, raw_state: rawptr) {
	state := (^Run_State)(raw_state)
	if glove.pressed(gbbfx.gfx_input(gfx), state.quit) {
		gbbfx.gfx_request_quit(gfx)
		return
	}
	state.update(state.app, &state.world, delta_time)
	world_update(&state.world, delta_time)
	world_render(&state.world)
}

@(private = "file")
run_destroy :: proc(gfx: ^gbbfx.Gfx, raw_state: rawptr) {
	state := (^Run_State)(raw_state)
	world_destroy(&state.world)
}
