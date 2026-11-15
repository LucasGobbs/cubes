package engine

import "gfx"
import input "input"
import "jobs"
import input_sdl "input/adapters/sdl"
import sdl "vendor:sdl3"

// Everything a scene touches: GPU device, input system, clock, loop state.
Context :: struct {
	gfx:             gfx.Device,
	jobs:            jobs.Pool, // CPU worker pool; see jobs package rules
	input:           input.System,
	using clock:     Clock,
	running:         bool,
	blend:           f32, // leftover of the fixed-step accumulator, 0..1 (P6)
	event_hook:      proc(event: ^sdl.Event, user: rawptr),
	event_hook_data: rawptr,
	camera:          Camera_Controller, // host-driven camera; nil = scene drives it
	camera_keys:     Maybe(Fly_Controls), // fly key actions, registered once per scene
}

context_create :: proc(
	ctx: ^Context,
	title: string,
	width, height: int,
	fullscreen, resizable, cursor: bool,
) -> bool {
	if !gfx.create(&ctx.gfx, title, width, height, fullscreen, resizable, cursor) do return false
	ctx.input = input.system_create(input_sdl.create())
	ctx.running = true
	return true
}

context_destroy :: proc(ctx: ^Context) {
	input.system_destroy(&ctx.input)
	gfx.destroy(&ctx.gfx)
}

// Raw SDL events after input processing; used by overlays (editor UI). hook = nil clears it.
set_event_hook :: proc(ctx: ^Context, hook: proc(event: ^sdl.Event, user: rawptr), user: rawptr) {
	ctx.event_hook = hook
	ctx.event_hook_data = user
}

request_quit :: proc(ctx: ^Context) {
	ctx.running = false
}
