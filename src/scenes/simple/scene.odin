// Simple scene: one textured ship, one unlit ship, one animated raw quad.
package simple

import "core:math/linalg"
import gbbfx "../../gbbfx"
import defaults "../../gbbfx/defaults"
import glove "../../glove"
import scenekit "../../scenekit"

Simple_State :: struct {
	textured_pipeline: gbbfx.Pipeline_Handle,
	unlit_pipeline:    gbbfx.Pipeline_Handle,
	sampler:           gbbfx.Sampler_Handle,
	textured_model:    gbbfx.Model,
	unlit_model:       gbbfx.Model,
	quad_mesh:         gbbfx.Mesh,
	quad_vertices:     [4]gbbfx.VertexData,
	quad_indices:      [6]u16,
	scene:             gbbfx.Scene,
	skybox:            defaults.Skybox,
	spinning:          int,
	rotation:          f32,
	fly_camera:        scenekit.FlyCamera,
	// move_action:       glove.Axis_2D_Action,
	// boost_action:      glove.Button_Action,
	// up_action:         glove.Button_Action,
	// down_action:       glove.Button_Action,
}

simple_scene :: proc() -> scenekit.Scene {
	return {name = "Simple", create = simple_create, tick = simple_tick, destroy = simple_destroy}
}

simple_create :: proc(demo: ^scenekit.Scene, dev: ^gbbfx.Device) -> bool {
	state := new(Simple_State)
	demo.state = state
	scenekit.scene_camera_reset(demo, dev)

	state.fly_camera = scenekit.fly_camera_create(dev, "simple")

	state.textured_pipeline = defaults.create_textured_pipeline(dev)
	state.unlit_pipeline = defaults.create_unlit_pipeline(dev)
	state.sampler = gbbfx.gfx_sampler_create(dev, gbbfx.SAMPLER_TRILINEAR)

	state.textured_model = scenekit.load_textured_model(
		dev,
		"static/models/sea/ship-large.glb",
		state.textured_pipeline,
		state.sampler,
	)
	state.unlit_model = gbbfx.gfx_load(
		dev,
		{model_path = "static/models/sea/ship-small-ghost.glb", pipeline = state.unlit_pipeline},
	)
	defaults.set_unlit_color(&state.unlit_model.material, {0.2, 0.8, 0.9, 1})

	state.skybox = defaults.skybox_create(dev, scenekit.SKYBOX_PATH)
	defaults.skybox_add_to_scene(&state.scene, &state.skybox)

	state.spinning = gbbfx.scene_add_model(
		&state.scene,
		&state.textured_model,
		{-2.5, -0.5, -10},
		{0.4, 0.4, 0.4},
	)
	gbbfx.scene_add_model(&state.scene, &state.unlit_model, {2.5, -0.5, -10}, {0.4, 0.4, 0.4})

	// Raw geometry: animated quad through the unlit pipeline.
	state.quad_vertices = {
		{position = {-1, -1, 0}, color = {1, 1, 1, 1}, normal = {0, 0, 1}, uv = {0, 0}},
		{position = {1, -1, 0}, color = {1, 1, 1, 1}, normal = {0, 0, 1}, uv = {1, 0}},
		{position = {1, 1, 0}, color = {1, 1, 1, 1}, normal = {0, 0, 1}, uv = {1, 1}},
		{position = {-1, 1, 0}, color = {1, 1, 1, 1}, normal = {0, 0, 1}, uv = {0, 1}},
	}
	state.quad_indices = {0, 1, 2, 2, 3, 0}
	state.quad_mesh = gbbfx.mesh_create(dev, state.quad_vertices[:], state.quad_indices[:])
	gbbfx.mesh_upload(&dev.renderer, &state.quad_mesh)
	quad := gbbfx.scene_add_entity(&state.scene)
	quad_entity := gbbfx.scene_entity(&state.scene, quad)
	gbbfx.entity_set_position(quad_entity, {0, 1.2, -8})
	gbbfx.entity_add_renderable(quad_entity, &state.quad_mesh, &state.unlit_model.material, .UI)
	return true
}

simple_tick :: proc(demo: ^scenekit.Scene, dev: ^gbbfx.Device, delta_time: f32) {
	state := cast(^Simple_State)demo.state

	scenekit.fly_camera_tick(&state.fly_camera, dev, delta_time)

	state.rotation += linalg.to_radians(f32(60)) * delta_time
	gbbfx.entity_set_rotation_euler(
		gbbfx.scene_entity(&state.scene, state.spinning),
		0,
		state.rotation,
		0,
	)

	state.quad_vertices[2].position.y = 1 + 0.5 * linalg.sin(dev.time * 2)
	state.quad_vertices[3].position.y = 1 - 0.5 * linalg.sin(dev.time * 2)
	gbbfx.mesh_update(
		&dev.renderer,
		&state.quad_mesh,
		state.quad_vertices[:],
		state.quad_indices[:],
	)

	gbbfx.gfx_render(dev, &state.scene)
}

simple_destroy :: proc(demo: ^scenekit.Scene, dev: ^gbbfx.Device) {
	state := cast(^Simple_State)demo.state
	gbbfx.scene_destroy(&state.scene)
	defaults.skybox_destroy(dev, &state.skybox)
	gbbfx.mesh_destroy(dev, &state.quad_mesh)
	gbbfx.gfx_unload(dev, &state.textured_model)
	gbbfx.gfx_unload(dev, &state.unlit_model)
	gbbfx.gfx_sampler_destroy(dev, state.sampler)
	gbbfx.gfx_pipeline_destroy(dev, state.textured_pipeline)
	gbbfx.gfx_pipeline_destroy(dev, state.unlit_pipeline)
	free(state)
}
