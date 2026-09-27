// Scenes: each scene file is a self-contained scene (assets, entities,
// input, camera, frame flow). main.odin picks one by CLI argument and runs
// it. Only the Scene interface and asset-loading utilities live here —
// every scene writes its own input and camera code.
package main

import gbbfx "gbbfx"
import defaults "gbbfx/defaults"
import loader "gbbfx/loader"
import "core:math/linalg"

Scene :: struct {
	name:      string,
	state:     rawptr,
	create:    proc(scene: ^Scene, gfx: ^gbbfx.Gfx) -> bool,
	tick:      proc(scene: ^Scene, gfx: ^gbbfx.Gfx, delta_time: f32),
	destroy:   proc(scene: ^Scene, gfx: ^gbbfx.Gfx),

	// Host bookkeeping; scenes don't touch this.
	fps_timer: f32,
}

SCENE_NAMES :: [4]string{"simple", "editor", "models", "benchmark"}

scene_lookup :: proc(name: string) -> (Scene, bool) {
	switch name {
	case "simple":
		return simple_scene(), true
	case "editor":
		return editor_scene(), true
	case "models":
		return models_scene(), true
	case "benchmark":
		return benchmark_scene(), true
	}
	return {}, false
}

// Restores the camera and the offscreen target to full-window defaults;
// demos call this in create because the editor demo shrinks both to its
// viewport widget.
camera_reset :: proc(
	gfx: ^gbbfx.Gfx,
	position := gbbfx.Vec3{0, 0, 3},
	target := gbbfx.Vec3{},
) {
	camera := gbbfx.gfx_camera(gfx)
	camera^ = gbbfx.camera_create(
		position = position,
		target = target,
		projection = linalg.matrix4_perspective(
			linalg.to_radians(f32(70)),
			gbbfx.gfx_aspect_ratio(gfx),
			0.1,
			1000,
		),
	)
	gbbfx.gfx_texture_resize(
		gfx,
		&gfx.renderer.scene_color,
		u32(gfx.window_size.x),
		u32(gfx.window_size.y),
	)
}

// Standalone texture load (no OBJ) for ground planes and raw meshes.
load_texture :: proc(gfx: ^gbbfx.Gfx, path: string) -> gbbfx.Texture_Handle {
	image := loader.image_load(path)
	handle := gbbfx.gfx_texture_create(gfx, image.width, image.height, .R8G8B8A8_UNORM, .SAMPLER)
	gbbfx.gfx_texture_get(gfx, handle)._temporary_raw_data = image.pixels
	gbbfx.uploader_begin(&gfx.renderer.uploader)
	gbbfx.uploader_upload_texture(&gfx.renderer.uploader, handle)
	gbbfx.uploader_flush_blocking(&gfx.renderer.uploader)
	gbbfx.gfx_texture_get(gfx, handle)._temporary_raw_data = nil
	return handle
}

load_textured_model :: proc(
	gfx: ^gbbfx.Gfx,
	model_path, texture_path: string,
	pipeline: gbbfx.Pipeline_Handle,
	sampler: gbbfx.Sampler_Handle,
) -> gbbfx.Model {
	model := gbbfx.gfx_load(
		gfx,
		{model_path = model_path, texture_path = texture_path, pipeline = pipeline},
	)
	defaults.bind_textured_material(&model.material, gbbfx.model_texture(&model), sampler)
	return model
}
