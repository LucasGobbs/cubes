package engine

import "gfx"
import "default"

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

// camera_reset using the scene's JSON camera (Scene.start_camera) when it has one;
// the arguments are the fallback for scenes without a definition.
scene_camera_reset :: proc(scene: ^Scene, gfx_ctx: ^gfx.Device, position := gfx.Vec3{0, 0, 3}, target := gfx.Vec3{}) {
	if start, ok := scene.start_camera.?; ok do default.camera_reset(gfx_ctx, start.position, start.look_at)
	else do default.camera_reset(gfx_ctx, position, target)
}
