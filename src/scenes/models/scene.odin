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
	draws:           [dynamic]gfx.Draw,
	skybox:          default.Skybox,
	model_draws:     [4]int,
	rotation:        f32,
	fly_camera:      default.Fly_Camera,
}

models_scene :: proc() -> engine.Scene {
	return {name = "Models", create = models_create, tick = models_tick, destroy = models_destroy}
}

// Models sit in a row along x, all at z = -16.
models_position :: proc(index: int) -> [3]f32 {
	return {(f32(index) - 1.5) * 8, 0, -16}
}

models_create :: proc(demo: ^engine.Scene, ctx: ^engine.Context) -> bool {
	dev := &ctx.gfx
	state := new(Models_State)
	demo.state = state
	engine.scene_camera_reset(demo, dev, {0, 2, 4})

	state.fly_camera = default.fly_camera_create(dev, &ctx.input, "models")

	state.pipeline = default.create_textured_pipeline(dev)
	state.sampler = gfx.sampler_create(dev, gfx.SAMPLER_TRILINEAR)

	for path, index in MODEL_PATHS {
		state.models[index] = default.load_textured_model(
			dev,
			path,
			state.pipeline,
			state.sampler,
		)
		append(
			&state.draws,
			gfx.draw_model(&state.models[index], models_position(index), MODEL_SCALE),
		)
		state.model_draws[index] = len(state.draws) - 1
	}

	// Ground plane: raw quad, tiled mud texture.
	state.skybox = default.skybox_create(dev, default.SKYBOX_PATH)
	append(&state.draws, default.skybox_draw(&state.skybox))

	state.ground_texture = gfx.texture_load(dev, "static/muddy_ground.jpg")
	state.ground_material = gfx.material_create(state.pipeline)
	default.bind_textured_material(&state.ground_material, state.ground_texture, state.sampler)
	tiling :: f32(40)
	ground_vertices := [4]gfx.VertexData {
		{position = {-100, -1, -100}, color = {1, 1, 1, 1}, normal = {0, 1, 0}, uv = {0, 0}},
		{position = {100, -1, -100}, color = {1, 1, 1, 1}, normal = {0, 1, 0}, uv = {tiling, 0}},
		{position = {100, -1, 100}, color = {1, 1, 1, 1}, normal = {0, 1, 0}, uv = {tiling, tiling}},
		{position = {-100, -1, 100}, color = {1, 1, 1, 1}, normal = {0, 1, 0}, uv = {0, tiling}},
	}
	ground_indices := [6]u16{0, 2, 1, 0, 3, 2}
	state.ground_mesh = gfx.mesh_create(dev, ground_vertices[:], ground_indices[:])
	gfx.mesh_upload(&dev.renderer, &state.ground_mesh)
	append(&state.draws, gfx.draw_make(&state.ground_mesh, &state.ground_material))
	return true
}

models_tick :: proc(demo: ^engine.Scene, ctx: ^engine.Context, delta_time: f32) {
	dev := &ctx.gfx
	state := cast(^Models_State)demo.state

	default.fly_camera_tick(&state.fly_camera, dev, &ctx.input, delta_time)

	state.rotation += delta_time
	for draw, index in state.model_draws {
		gfx.draw_set_transform(
			&state.draws[draw],
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
	gfx.render(dev, state.draws[:])
}

models_destroy :: proc(demo: ^engine.Scene, ctx: ^engine.Context) {
	dev := &ctx.gfx
	state := cast(^Models_State)demo.state
	delete(state.draws)
	default.skybox_destroy(dev, &state.skybox)
	gfx.mesh_destroy(dev, &state.ground_mesh)
	gfx.material_destroy(&state.ground_material)
	gfx.texture_destroy(dev, state.ground_texture)
	for &model in state.models do gfx.model_unload(dev, &model)
	gfx.sampler_destroy(dev, state.sampler)
	gfx.pipeline_destroy(dev, state.pipeline)
	free(state)
}
