// Shared scene plumbing: the Scene interface and helpers every scene uses
// (camera reset, textured model loading, fly camera). Scenes live in
// src/scenes/<name>/ and import this package; the host registry is src/scene.odin.
package scenekit

import gbbfx "../gbbfx"
import defaults "../gbbfx/defaults"

SKYBOX_PATH :: "static/skybox/skybox-day.png"

Camera_Start :: struct {
	position, look_at: gbbfx.Vec3,
}

Scene :: struct {
	name:      string,
	definition: string, // JSON definition path for data-driven scenes; empty otherwise
	start_camera: Maybe(Camera_Start), // from the scene's JSON file, set by the host
	state:     rawptr,
	create:    proc(scene: ^Scene, dev: ^gbbfx.Device) -> bool,
	tick:      proc(scene: ^Scene, dev: ^gbbfx.Device, delta_time: f32),
	destroy:   proc(scene: ^Scene, dev: ^gbbfx.Device),

	// Host bookkeeping; scenes don't touch this.
	fps_timer: f32,
}

// camera_reset using the scene's JSON camera (Scene.start_camera) when it has one;
// the arguments are the fallback for scenes without a definition.
scene_camera_reset :: proc(scene: ^Scene, dev: ^gbbfx.Device, position := gbbfx.Vec3{0, 0, 3}, target := gbbfx.Vec3{}) {
	if start, ok := scene.start_camera.?; ok do camera_reset(dev, start.position, start.look_at)
	else do camera_reset(dev, position, target)
}

// Restores the camera and the offscreen targets to full-window defaults;
// demos call this in create because the editor demo shrinks both to its
// viewport widget.
camera_reset :: proc(dev: ^gbbfx.Device, position := gbbfx.Vec3{0, 0, 3}, target := gbbfx.Vec3{}) {
	camera := gbbfx.gfx_camera(dev)
	camera^ = gbbfx.camera_create(
		position = position,
		target = target,
		projection = gbbfx.camera_perspective(gbbfx.gfx_aspect_ratio(dev)),
	)
	gbbfx.renderer_resize_targets(&dev.renderer, u32(dev.window_size.x), u32(dev.window_size.y))
}

// Loads a .glb/.gltf and binds its base color texture to the default
// textured material.
load_textured_model :: proc(
	dev: ^gbbfx.Device,
	model_path: string,
	pipeline: gbbfx.Pipeline_Handle,
	sampler: gbbfx.Sampler_Handle,
) -> gbbfx.Model {
	model := gbbfx.gfx_load(dev, {model_path = model_path, pipeline = pipeline})
	defaults.bind_textured_material(&model.material, gbbfx.model_texture(&model), sampler)
	return model
}
