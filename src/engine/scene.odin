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

	// Optional async loading. `load` runs on a job thread before `create` (CPU work only: no
	// gfx/b3/scope calls, see the jobs package) and may allocate scene.state; `create` then uses it.
	// Report progress with load_progress. `unload` frees what `load` allocated when the result is
	// dropped without a create (a replaced preload). Scenes without `load` are created as before.
	load:   proc(scene: ^Scene, lc: ^Load_Context) -> bool,
	unload: proc(scene: ^Scene),

	// Optional scene-stack hooks for Stack_Policy.Disk: write what `resume` needs to `path` when
	// the scene is pushed under another one, and read it back after `create` on pop.
	suspend: proc(scene: ^Scene, ctx: ^Context, path: string) -> bool,
	resume:  proc(scene: ^Scene, ctx: ^Context, path: string) -> bool,

	// Host bookkeeping; scenes don't touch this.
	fps_timer: f32,
}
