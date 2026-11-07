// Skinned: one rigged glTF character playing its first animation clip.
package main

import gbbfx "gbbfx"
import defaults "gbbfx/defaults"
import loader "gbbfx/loader"

SKINNED_MODEL_PATH :: "static/models/rigged_cesiumman.glb"
SKINNED_CLIP :: "clip_0"

Skinned_State :: struct {
	pipeline: gbbfx.Pipeline_Handle,
	sampler:  gbbfx.Sampler_Handle,
	model:    gbbfx.Model,
	scene:    gbbfx.Scene,
	entity:   int,
}

skinned_demo_scene :: proc() -> Scene {
	return {name = "Skinned", create = skinned_create, tick = skinned_tick, destroy = skinned_destroy}
}

skinned_create :: proc(demo: ^Scene, gfx: ^gbbfx.Gfx) -> bool {
	state := new(Skinned_State)
	demo.state = state
	camera_reset(gfx, {0, 1.0, 1.9}, {0, 0.8, 0})

	state.pipeline = defaults.create_textured_skinned_pipeline(gfx)
	state.sampler = gbbfx.gfx_sampler_create(gfx, gbbfx.SAMPLER_TRILINEAR)

	imported, ok := loader.model_import_skinned_from_gltf(SKINNED_MODEL_PATH)
	if !ok do return false
	defer loader.skinned_model_destroy(&imported)
	state.model = gbbfx.skinned_model_create(gfx, &imported, state.pipeline)
	gbbfx.model_upload_to_gpu(&state.model, &gfx.renderer.uploader)
	defaults.bind_textured_skinned_material(
		&state.model.material,
		gbbfx.model_texture(&state.model),
		state.sampler,
	)

	state.entity = gbbfx.scene_add_entity(&state.scene)
	entity := gbbfx.scene_entity(&state.scene, state.entity)
	gbbfx.entity_add_skinned_renderable(
		entity,
		&state.model.mesh,
		&state.model.material,
		&state.model.skin,
	)
	if !gbbfx.entity_play_clip(entity, SKINNED_CLIP) do return false
	return true
}

skinned_tick :: proc(demo: ^Scene, gfx: ^gbbfx.Gfx, delta_time: f32) {
	state := cast(^Skinned_State)demo.state
	gbbfx.scene_tick_animations(&state.scene, delta_time)
	gbbfx.gfx_render(gfx, &state.scene)
}

skinned_destroy :: proc(demo: ^Scene, gfx: ^gbbfx.Gfx) {
	state := cast(^Skinned_State)demo.state
	gbbfx.scene_destroy(&state.scene)
	gbbfx.gfx_unload(gfx, &state.model)
	gbbfx.gfx_sampler_destroy(gfx, state.sampler)
	gbbfx.gfx_pipeline_destroy(gfx, state.pipeline)
	free(state)
}
