// Key 3 — Models: every OBJ in static/ on a textured ground plane, each
// rotating at its own speed.
package models

import gfx "../../engine/gfx"
import default "../../engine/default"
import engine "../../engine"

MODEL_PATHS :: [4]string {
	"static/models/sea/boat-tug-a.glb",
	"static/models/sea/ship-cargo-a.glb",
	"static/models/sea/ship-large.glb",
	"static/models/sea/ship-small-ghost.glb",
}

Models_State :: struct {
	pipeline:        gfx.Pipeline_Handle,
	sampler:         gfx.Sampler_Handle,
	models:          [4]gfx.Model,
	ground_texture:  gfx.Texture_Handle,
	ground_material: gfx.Material,
	ground_mesh:     gfx.Mesh,
	scene:           gfx.Scene,
	skybox:          default.Skybox,
	entities:        [4]int,
	rotation:        f32,
	fly_camera:      default.Fly_Camera,
}

models_scene :: proc() -> engine.Scene {
	return {name = "Models", create = models_create, tick = models_tick, destroy = models_destroy}
}

models_create :: proc(demo: ^engine.Scene, dev: ^gfx.Device) -> bool {
	state := new(Models_State)
	demo.state = state
	engine.scene_camera_reset(demo, dev, {0, 2, 4})

	state.fly_camera = default.fly_camera_create(dev, "models")

	state.pipeline = default.create_textured_pipeline(dev)
	state.sampler = gfx.gfx_sampler_create(dev, gfx.SAMPLER_TRILINEAR)

	for path, index in MODEL_PATHS {
		state.models[index] = default.load_textured_model(
			dev,
			path,
			state.pipeline,
			state.sampler,
		)
		x := (f32(index) - 1.5) * 8
		state.entities[index] = gfx.scene_add_model(
			&state.scene,
			&state.models[index],
			{x, 0, -16},
			{0.5, 0.5, 0.5},
		)
	}

	// Ground plane: raw quad, tiled mud texture.
	state.skybox = default.skybox_create(dev, default.SKYBOX_PATH)
	default.skybox_add_to_scene(&state.scene, &state.skybox)

	state.ground_texture = gfx.gfx_texture_load(dev, "static/muddy_ground.jpg")
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
	ground := gfx.scene_add_entity(&state.scene)
	ground_entity := gfx.scene_entity(&state.scene, ground)
	gfx.entity_add_renderable(ground_entity, &state.ground_mesh, &state.ground_material)
	return true
}

models_tick :: proc(demo: ^engine.Scene, dev: ^gfx.Device, delta_time: f32) {
	state := cast(^Models_State)demo.state

	default.fly_camera_tick(&state.fly_camera, dev, delta_time)

	state.rotation += delta_time
	for entity, index in state.entities {
		gfx.entity_set_rotation_euler(
			gfx.scene_entity(&state.scene, entity),
			0,
			state.rotation * (0.4 + 0.3 * f32(index)),
			0,
		)
	}
	gfx.gfx_render(dev, &state.scene)
}

models_destroy :: proc(demo: ^engine.Scene, dev: ^gfx.Device) {
	state := cast(^Models_State)demo.state
	gfx.scene_destroy(&state.scene)
	default.skybox_destroy(dev, &state.skybox)
	gfx.mesh_destroy(dev, &state.ground_mesh)
	gfx.material_destroy(&state.ground_material)
	gfx.gfx_texture_destroy(dev, state.ground_texture)
	for &model in state.models do gfx.gfx_unload(dev, &model)
	gfx.gfx_sampler_destroy(dev, state.sampler)
	gfx.gfx_pipeline_destroy(dev, state.pipeline)
	free(state)
}
