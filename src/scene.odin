// Scenes: each scene file is a self-contained scene (assets, entities,
// input, camera, frame flow). main.odin picks one by CLI argument and runs
// it. Only the Scene interface and asset-loading utilities live here —
// every scene writes its own input and camera code.
package main

import gbbfx "gbbfx"
import defaults "gbbfx/defaults"

SKYBOX_PATH :: "static/skybox/skybox-day.png"

Scene :: struct {
	name:      string,
	state:     rawptr,
	create:    proc(scene: ^Scene, gfx: ^gbbfx.Gfx) -> bool,
	tick:      proc(scene: ^Scene, gfx: ^gbbfx.Gfx, delta_time: f32),
	destroy:   proc(scene: ^Scene, gfx: ^gbbfx.Gfx),

	// Host bookkeeping; scenes don't touch this.
	fps_timer: f32,
}

SceneEntry :: struct {
	name: string,
	make: proc() -> Scene,
}

SCENES := [?]SceneEntry {
	{"simple", simple_scene},
	{"editor", editor_scene},
	{"models", models_scene},
	{"skinned", skinned_demo_scene},
	{"postfx", postfx_demo_scene},
	{"game", game_demo_scene},
	{"platform", platform_scene},
	{"benchmark", benchmark_scene},
}

scene_lookup :: proc(name: string) -> (Scene, bool) {
	for scene in SCENES {
		if scene.name == name do return scene.make(), true
	}

	return {}, false
}

// Restores the camera and the offscreen targets to full-window defaults;
// demos call this in create because the editor demo shrinks both to its
// viewport widget.
camera_reset :: proc(gfx: ^gbbfx.Gfx, position := gbbfx.Vec3{0, 0, 3}, target := gbbfx.Vec3{}) {
	camera := gbbfx.gfx_camera(gfx)
	camera^ = gbbfx.camera_create(
		position = position,
		target = target,
		projection = gbbfx.camera_perspective(gbbfx.gfx_aspect_ratio(gfx)),
	)
	gbbfx.renderer_resize_targets(&gfx.renderer, u32(gfx.window_size.x), u32(gfx.window_size.y))
}

// Loads a .glb/.gltf and binds its base color texture to the default
// textured material.
load_textured_model :: proc(
	gfx: ^gbbfx.Gfx,
	model_path: string,
	pipeline: gbbfx.Pipeline_Handle,
	sampler: gbbfx.Sampler_Handle,
) -> gbbfx.Model {
	model := gbbfx.gfx_load(gfx, {model_path = model_path, pipeline = pipeline})
	defaults.bind_textured_material(&model.material, gbbfx.model_texture(&model), sampler)
	return model
}
