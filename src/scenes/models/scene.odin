// Key 3 — Models: every OBJ in static/ on a textured ground plane, each
// rotating at its own speed.
package models

import "core:math/linalg"
import gfx "../../engine/gfx"
import default "../../engine/default"
import engine "../../engine"

MODEL_PATHS :: [4]string {
	"static/models/sea/boat-tug-a.glb",
	"static/models/sea/ship-cargo-a.glb",
	"static/models/sea/ship-large.glb",
	"static/models/sea/ship-small-ghost.glb",
}

MODEL_SCALE :: [3]f32{0.5, 0.5, 0.5}

Models_State :: struct {
	pipeline:        gfx.Pipeline_Handle,
	sampler:         gfx.Sampler_Handle,
	models:          [4]gfx.Model,
	ground_texture:  gfx.Texture_Handle,
	ground_material: gfx.Material,
	ground_mesh:     gfx.Mesh,
	model_draws:     [4]int,
	rotation:        f32,
	fly_camera:      gfx.Fly_Camera,
	fly_controls:    engine.Fly_Controls,
}

models_scene :: proc() -> engine.Scene {
	return {name = "Models", create = models_create, tick = models_tick, destroy = models_destroy}
}

// Models sit in a row along x, all at z = -16.
models_position :: proc(index: int) -> [3]f32 {
	return {(f32(index) - 1.5) * 8, 0, -16}
}

models_create :: proc(demo: ^engine.Scene, ctx: ^engine.Context) -> bool {
	gfx_ctx := &ctx.gfx
	state := new(Models_State)
	demo.state = state
	engine.scene_camera_reset(demo, gfx_ctx, {0, 2, 4})

	state.fly_camera = gfx.fly_camera_create()
	state.fly_controls = engine.fly_controls_create(&ctx.input, "models")

	state.pipeline = gfx.create_textured_pipeline(gfx_ctx)
	state.sampler = gfx.sampler_create(gfx_ctx, gfx.SAMPLER_TRILINEAR)

	for path, index in MODEL_PATHS {
		state.models[index] = gfx.load_textured_model(
			gfx_ctx,
			path,
			state.pipeline,
			state.sampler,
		)
		state.model_draws[index] = gfx.draw_add(
			gfx_ctx,
			gfx.draw_model(&state.models[index], models_position(index), MODEL_SCALE),
		)
	}

	// Ground plane: raw quad, tiled mud texture.
	gfx.skybox_add(gfx_ctx, default.SKYBOX_PATH)

	state.ground_texture = gfx.texture_load(gfx_ctx, "static/muddy_ground.jpg")
	state.ground_material = gfx.material_create(state.pipeline)
	gfx.bind_textured_material(&state.ground_material, state.ground_texture, state.sampler)
	tiling :: f32(40)
	ground_vertices := [4]gfx.VertexData {
		{position = {-100, -1, -100}, color = {1, 1, 1, 1}, normal = {0, 1, 0}, uv = {0, 0}},
		{position = {100, -1, -100}, color = {1, 1, 1, 1}, normal = {0, 1, 0}, uv = {tiling, 0}},
		{position = {100, -1, 100}, color = {1, 1, 1, 1}, normal = {0, 1, 0}, uv = {tiling, tiling}},
		{position = {-100, -1, 100}, color = {1, 1, 1, 1}, normal = {0, 1, 0}, uv = {0, tiling}},
	}
	ground_indices := [6]u16{0, 2, 1, 0, 3, 2}
	state.ground_mesh = gfx.mesh_create(gfx_ctx, ground_vertices[:], ground_indices[:])
	gfx.mesh_upload(&gfx_ctx.renderer, &state.ground_mesh)
	gfx.draw_add(gfx_ctx, gfx.draw_make(&state.ground_mesh, &state.ground_material))
	return true
}

models_tick :: proc(demo: ^engine.Scene, ctx: ^engine.Context, delta_time: f32) {
	gfx_ctx := &ctx.gfx
	state := cast(^Models_State)demo.state

	fly := engine.fly_controls_read(&ctx.input, &state.fly_controls)
	gfx.fly_camera_update(gfx.camera(gfx_ctx), &state.fly_camera, fly, delta_time)

	state.rotation += delta_time
	for draw, index in state.model_draws {
		gfx.draw_set_transform(
			gfx.draw_get(gfx_ctx, draw),
			models_position(index),
			linalg.quaternion_from_euler_angles_f32(
				0,
				state.rotation * (0.4 + 0.3 * f32(index)),
				0,
				.XYZ,
			),
			MODEL_SCALE,
		)
	}
	gfx.render(gfx_ctx)
}

models_destroy :: proc(demo: ^engine.Scene, ctx: ^engine.Context) {
	gfx_ctx := &ctx.gfx
	state := cast(^Models_State)demo.state
	gfx.material_destroy(&state.ground_material)
	for &model in state.models do gfx.model_unload(gfx_ctx, &model)
	free(state)
}
