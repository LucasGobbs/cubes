// Skinned: one rigged glTF character playing its first animation clip.
package skinned

import gfx "../../engine/gfx"
import default "../../engine/default"
import loader "../../engine/gfx/loader"
import engine "../../engine"

SKINNED_MODEL_PATH :: "static/models/rigged_cesiumman.glb"
SKINNED_CLIP :: "clip_0"

Skinned_State :: struct {
	pipeline: gfx.Pipeline_Handle,
	sampler:  gfx.Sampler_Handle,
	model:    gfx.Model,
	draws:    [dynamic]gfx.Draw,
	playback: gfx.Playback,
}

skinned_scene :: proc() -> engine.Scene {
	return {name = "Skinned", create = skinned_create, tick = skinned_tick, destroy = skinned_destroy}
}

skinned_create :: proc(demo: ^engine.Scene, dev: ^gfx.Device) -> bool {
	state := new(Skinned_State)
	demo.state = state
	engine.scene_camera_reset(demo, dev, {0, 1.0, 1.9}, {0, 0.8, 0})

	state.pipeline = default.create_textured_skinned_pipeline(dev)
	state.sampler = gfx.sampler_create(dev, gfx.SAMPLER_TRILINEAR)

	imported, ok := loader.model_import_skinned_from_gltf(SKINNED_MODEL_PATH)
	if !ok do return false
	defer loader.skinned_model_destroy(&imported)
	state.model = gfx.model_create_skinned(dev, &imported, state.pipeline)
	gfx.model_upload_to_gpu(&state.model, &dev.renderer.uploader)
	default.bind_textured_skinned_material(
		&state.model.material,
		gfx.model_texture(&state.model),
		state.sampler,
	)

	state.playback = gfx.playback_create(&state.model.skin)
	if !gfx.playback_play(&state.playback, SKINNED_CLIP) do return false

	// Skinned meshes have no bounds (see mesh_set_bounds), so culling stays off.
	draw := gfx.draw_make(&state.model.mesh, &state.model.material)
	draw.cull = false
	draw.pose = state.playback.pose
	append(&state.draws, draw)
	return true
}

skinned_tick :: proc(demo: ^engine.Scene, dev: ^gfx.Device, delta_time: f32) {
	state := cast(^Skinned_State)demo.state
	gfx.playback_tick(&state.playback, delta_time)
	gfx.render(dev, state.draws[:])
}

skinned_destroy :: proc(demo: ^engine.Scene, dev: ^gfx.Device) {
	state := cast(^Skinned_State)demo.state
	delete(state.draws)
	gfx.playback_destroy(&state.playback)
	gfx.model_unload(dev, &state.model)
	gfx.sampler_destroy(dev, state.sampler)
	gfx.pipeline_destroy(dev, state.pipeline)
	free(state)
}
