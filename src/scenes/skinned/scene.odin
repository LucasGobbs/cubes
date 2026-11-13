// Skinned: one rigged glTF character playing its first animation clip.
package skinned

import engine "../../engine"
import gfx "../../engine/gfx"
import loader "../../engine/gfx/loader"

SKINNED_MODEL_PATH :: "static/models/rigged_cesiumman.glb"
SKINNED_CLIP :: "clip_0"

Skinned_State :: struct {
	pipeline: gfx.Pipeline_Handle,
	sampler:  gfx.Sampler_Handle,
	model:    gfx.Model,
	playback: gfx.Playback,
}

skinned_scene :: proc() -> engine.Scene {
	return {
		name = "Skinned",
		create = skinned_create,
		tick = skinned_tick,
		destroy = skinned_destroy,
	}
}

skinned_create :: proc(demo: ^engine.Scene, ctx: ^engine.Context) -> bool {
	gfx_ctx := &ctx.gfx
	state := new(Skinned_State)
	demo.state = state
	engine.scene_camera_reset(demo, gfx_ctx, {0, 1.0, 1.9}, {0, 0.8, 0})

	state.pipeline = gfx.create_textured_skinned_pipeline(gfx_ctx)
	state.sampler = gfx.sampler_create(gfx_ctx, gfx.SAMPLER_TRILINEAR)

	imported, ok := loader.model_import_skinned_from_gltf(SKINNED_MODEL_PATH)
	if !ok do return false
	defer loader.skinned_model_destroy(&imported)
	state.model = gfx.model_create_skinned(gfx_ctx, &imported, state.pipeline)
	gfx.model_upload_to_gpu(&state.model, &gfx_ctx.renderer.uploader)
	gfx.bind_textured_skinned_material(
		&state.model.material,
		gfx.model_texture(&state.model),
		state.sampler,
	)

	state.playback = gfx.playback_create(&state.model.skin)
	if !gfx.playback_play(&state.playback, SKINNED_CLIP) do return false

	// Skinned meshes have no bounds (see mesh_set_bounds), so culling stays off.
	index := gfx.draw_create(gfx_ctx, {mesh = &state.model})
	draw := gfx.draw_get(gfx_ctx, index)
	draw.cull = false
	draw.pose = state.playback.pose
	return true
}

skinned_tick :: proc(demo: ^engine.Scene, ctx: ^engine.Context, delta_time: f32) {
	gfx_ctx := &ctx.gfx
	state := cast(^Skinned_State)demo.state
	gfx.playback_tick(&state.playback, delta_time)
	gfx.render(gfx_ctx)
}

skinned_destroy :: proc(demo: ^engine.Scene, ctx: ^engine.Context) {
	gfx_ctx := &ctx.gfx
	state := cast(^Skinned_State)demo.state
	gfx.playback_destroy(&state.playback)
	gfx.model_unload(gfx_ctx, &state.model)
	free(state)
}
