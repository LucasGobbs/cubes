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
	scene:    gfx.Scene,
	entity:   int,
}

skinned_scene :: proc() -> engine.Scene {
	return {name = "Skinned", create = skinned_create, tick = skinned_tick, destroy = skinned_destroy}
}

skinned_create :: proc(demo: ^engine.Scene, dev: ^gfx.Device) -> bool {
	state := new(Skinned_State)
	demo.state = state
	engine.scene_camera_reset(demo, dev, {0, 1.0, 1.9}, {0, 0.8, 0})

	state.pipeline = default.create_textured_skinned_pipeline(dev)
	state.sampler = gfx.gfx_sampler_create(dev, gfx.SAMPLER_TRILINEAR)

	imported, ok := loader.model_import_skinned_from_gltf(SKINNED_MODEL_PATH)
	if !ok do return false
	defer loader.skinned_model_destroy(&imported)
	state.model = gfx.skinned_model_create(dev, &imported, state.pipeline)
	gfx.model_upload_to_gpu(&state.model, &dev.renderer.uploader)
	default.bind_textured_skinned_material(
		&state.model.material,
		gfx.model_texture(&state.model),
		state.sampler,
	)

	state.entity = gfx.scene_add_entity(&state.scene)
	entity := gfx.scene_entity(&state.scene, state.entity)
	gfx.entity_add_skinned_renderable(
		entity,
		&state.model.mesh,
		&state.model.material,
		&state.model.skin,
	)
	if !gfx.entity_play_clip(entity, SKINNED_CLIP) do return false
	return true
}

skinned_tick :: proc(demo: ^engine.Scene, dev: ^gfx.Device, delta_time: f32) {
	state := cast(^Skinned_State)demo.state
	gfx.scene_tick_animations(&state.scene, delta_time)
	gfx.gfx_render(dev, &state.scene)
}

skinned_destroy :: proc(demo: ^engine.Scene, dev: ^gfx.Device) {
	state := cast(^Skinned_State)demo.state
	gfx.scene_destroy(&state.scene)
	gfx.gfx_unload(dev, &state.model)
	gfx.gfx_sampler_destroy(dev, state.sampler)
	gfx.gfx_pipeline_destroy(dev, state.pipeline)
	free(state)
}
