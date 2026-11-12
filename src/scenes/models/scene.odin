// Key 3 — Models: every OBJ in static/ on a textured ground plane, each
// rotating at its own speed.
package models

import gbbfx "../../gbbfx"
import defaults "../../gbbfx/defaults"
import scenekit "../../scenekit"

MODEL_PATHS :: [4]string {
	"static/models/sea/boat-tug-a.glb",
	"static/models/sea/ship-cargo-a.glb",
	"static/models/sea/ship-large.glb",
	"static/models/sea/ship-small-ghost.glb",
}

Models_State :: struct {
	pipeline:        gbbfx.Pipeline_Handle,
	sampler:         gbbfx.Sampler_Handle,
	models:          [4]gbbfx.Model,
	ground_texture:  gbbfx.Texture_Handle,
	ground_material: gbbfx.Material,
	ground_mesh:     gbbfx.Mesh,
	scene:           gbbfx.Scene,
	skybox:          defaults.Skybox,
	entities:        [4]int,
	rotation:        f32,
	fly_camera:      scenekit.FlyCamera,
}

models_scene :: proc() -> scenekit.Scene {
	return {name = "Models", create = models_create, tick = models_tick, destroy = models_destroy}
}

models_create :: proc(demo: ^scenekit.Scene, dev: ^gbbfx.Device) -> bool {
	state := new(Models_State)
	demo.state = state
	scenekit.scene_camera_reset(demo, dev, {0, 2, 4})

	state.fly_camera = scenekit.fly_camera_create(dev, "models")

	state.pipeline = defaults.create_textured_pipeline(dev)
	state.sampler = gbbfx.gfx_sampler_create(dev, gbbfx.SAMPLER_TRILINEAR)

	for path, index in MODEL_PATHS {
		state.models[index] = scenekit.load_textured_model(
			dev,
			path,
			state.pipeline,
			state.sampler,
		)
		x := (f32(index) - 1.5) * 8
		state.entities[index] = gbbfx.scene_add_model(
			&state.scene,
			&state.models[index],
			{x, 0, -16},
			{0.5, 0.5, 0.5},
		)
	}

	// Ground plane: raw quad, tiled mud texture.
	state.skybox = defaults.skybox_create(dev, scenekit.SKYBOX_PATH)
	defaults.skybox_add_to_scene(&state.scene, &state.skybox)

	state.ground_texture = gbbfx.gfx_texture_load(dev, "static/muddy_ground.jpg")
	state.ground_material = gbbfx.material_create(state.pipeline)
	defaults.bind_textured_material(&state.ground_material, state.ground_texture, state.sampler)
	tiling :: f32(40)
	ground_vertices := [4]gbbfx.VertexData {
		{position = {-100, -1, -100}, color = {1, 1, 1, 1}, normal = {0, 1, 0}, uv = {0, 0}},
		{position = {100, -1, -100}, color = {1, 1, 1, 1}, normal = {0, 1, 0}, uv = {tiling, 0}},
		{position = {100, -1, 100}, color = {1, 1, 1, 1}, normal = {0, 1, 0}, uv = {tiling, tiling}},
		{position = {-100, -1, 100}, color = {1, 1, 1, 1}, normal = {0, 1, 0}, uv = {0, tiling}},
	}
	ground_indices := [6]u16{0, 2, 1, 0, 3, 2}
	state.ground_mesh = gbbfx.mesh_create(dev, ground_vertices[:], ground_indices[:])
	gbbfx.mesh_upload(&dev.renderer, &state.ground_mesh)
	ground := gbbfx.scene_add_entity(&state.scene)
	ground_entity := gbbfx.scene_entity(&state.scene, ground)
	gbbfx.entity_add_renderable(ground_entity, &state.ground_mesh, &state.ground_material)
	return true
}

models_tick :: proc(demo: ^scenekit.Scene, dev: ^gbbfx.Device, delta_time: f32) {
	state := cast(^Models_State)demo.state

	scenekit.fly_camera_tick(&state.fly_camera, dev, delta_time)

	state.rotation += delta_time
	for entity, index in state.entities {
		gbbfx.entity_set_rotation_euler(
			gbbfx.scene_entity(&state.scene, entity),
			0,
			state.rotation * (0.4 + 0.3 * f32(index)),
			0,
		)
	}
	gbbfx.gfx_render(dev, &state.scene)
}

models_destroy :: proc(demo: ^scenekit.Scene, dev: ^gbbfx.Device) {
	state := cast(^Models_State)demo.state
	gbbfx.scene_destroy(&state.scene)
	defaults.skybox_destroy(dev, &state.skybox)
	gbbfx.mesh_destroy(dev, &state.ground_mesh)
	gbbfx.material_destroy(&state.ground_material)
	gbbfx.gfx_texture_destroy(dev, state.ground_texture)
	for &model in state.models do gbbfx.gfx_unload(dev, &model)
	gbbfx.gfx_sampler_destroy(dev, state.sampler)
	gbbfx.gfx_pipeline_destroy(dev, state.pipeline)
	free(state)
}
