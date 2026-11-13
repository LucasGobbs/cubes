package engine

import gfx "gfx"

Camera_Start :: struct {
	position, look_at: gfx.Vec3,
}

Scene :: struct {
	name:      string,
	definition: string, // JSON definition path for data-driven scenes; empty otherwise
	start_camera: Maybe(Camera_Start), // from the scene's JSON file, set by the host
	state:     rawptr,
	create:    proc(scene: ^Scene, ctx: ^Context) -> bool,
	tick:      proc(scene: ^Scene, ctx: ^Context, delta_time: f32),
	destroy:   proc(scene: ^Scene, ctx: ^Context),
	fixed_tick: proc(scene: ^Scene, ctx: ^Context, dt: f32), // optional; fixed-rate step, see Config.fixed_hz

	// Host bookkeeping; scenes don't touch this.
	fps_timer: f32,
}
