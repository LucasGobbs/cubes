// Simple scene: one textured ship, one unlit ship, one animated raw quad.
package simple

import "core:math/linalg"
import gfx "../../engine/gfx"
import default "../../engine/default"
import input "../../engine/input"
import engine "../../engine"

Simple_State :: struct {
	textured_pipeline: gfx.Pipeline_Handle,
	unlit_pipeline:    gfx.Pipeline_Handle,
	sampler:           gfx.Sampler_Handle,
	textured_model:    gfx.Model,
	unlit_model:       gfx.Model,
	quad_mesh:         gfx.Mesh,
	quad_vertices:     [4]gfx.VertexData,
	quad_indices:      [6]u16,
	scene:             gfx.Scene,
	skybox:            default.Skybox,
	spinning:          int,
	rotation:          f32,
	fly_camera:        default.Fly_Camera,
	// move_action:       input.Axis_2D_Action,
	// boost_action:      input.Button_Action,
	// up_action:         input.Button_Action,
	// down_action:       input.Button_Action,
}

simple_scene :: proc() -> engine.Scene {
	return {name = "Simple", create = simple_create, tick = simple_tick, destroy = simple_destroy}
}

simple_create :: proc(demo: ^engine.Scene, dev: ^gfx.Device) -> bool {
	state := new(Simple_State)
	demo.state = state
	engine.scene_camera_reset(demo, dev)

	state.fly_camera = default.fly_camera_create(dev, "simple")

	state.textured_pipeline = default.create_textured_pipeline(dev)
	state.unlit_pipeline = default.create_unlit_pipeline(dev)
	state.sampler = gfx.sampler_create(dev, gfx.SAMPLER_TRILINEAR)

	state.textured_model = default.load_textured_model(
		dev,
		"static/models/sea/ship-large.glb",
		state.textured_pipeline,
		state.sampler,
	)
	state.unlit_model = gfx.model_load(
		dev,
		{model_path = "static/models/sea/ship-small-ghost.glb", pipeline = state.unlit_pipeline},
	)
	default.set_unlit_color(&state.unlit_model.material, {0.2, 0.8, 0.9, 1})

	state.skybox = default.skybox_create(dev, default.SKYBOX_PATH)
	default.skybox_add_to_scene(&state.scene, &state.skybox)

	state.spinning = gfx.scene_add_model(
		&state.scene,
		&state.textured_model,
		{-2.5, -0.5, -10},
		{0.4, 0.4, 0.4},
	)
	gfx.scene_add_model(&state.scene, &state.unlit_model, {2.5, -0.5, -10}, {0.4, 0.4, 0.4})

	// Raw geometry: animated quad through the unlit pipeline.
	state.quad_vertices = {
		{position = {-1, -1, 0}, color = {1, 1, 1, 1}, normal = {0, 0, 1}, uv = {0, 0}},
		{position = {1, -1, 0}, color = {1, 1, 1, 1}, normal = {0, 0, 1}, uv = {1, 0}},
		{position = {1, 1, 0}, color = {1, 1, 1, 1}, normal = {0, 0, 1}, uv = {1, 1}},
		{position = {-1, 1, 0}, color = {1, 1, 1, 1}, normal = {0, 0, 1}, uv = {0, 1}},
	}
	state.quad_indices = {0, 1, 2, 2, 3, 0}
	state.quad_mesh = gfx.mesh_create(dev, state.quad_vertices[:], state.quad_indices[:])
	gfx.mesh_upload(&dev.renderer, &state.quad_mesh)
	quad := gfx.scene_add_entity(&state.scene)
	quad_entity := gfx.scene_entity(&state.scene, quad)
	gfx.entity_set_position(quad_entity, {0, 1.2, -8})
	gfx.entity_add_renderable(quad_entity, &state.quad_mesh, &state.unlit_model.material, .UI)
	return true
}

simple_tick :: proc(demo: ^engine.Scene, dev: ^gfx.Device, delta_time: f32) {
	state := cast(^Simple_State)demo.state

	default.fly_camera_tick(&state.fly_camera, dev, delta_time)

	state.rotation += linalg.to_radians(f32(60)) * delta_time
	gfx.entity_set_rotation_euler(
		gfx.scene_entity(&state.scene, state.spinning),
		0,
		state.rotation,
		0,
	)

	state.quad_vertices[2].position.y = 1 + 0.5 * linalg.sin(dev.time * 2)
	state.quad_vertices[3].position.y = 1 - 0.5 * linalg.sin(dev.time * 2)
	gfx.mesh_update(
		&dev.renderer,
		&state.quad_mesh,
		state.quad_vertices[:],
		state.quad_indices[:],
	)

	gfx.gfx_render(dev, &state.scene)
}

simple_destroy :: proc(demo: ^engine.Scene, dev: ^gfx.Device) {
	state := cast(^Simple_State)demo.state
	gfx.scene_destroy(&state.scene)
	default.skybox_destroy(dev, &state.skybox)
	gfx.mesh_destroy(dev, &state.quad_mesh)
	gfx.model_unload(dev, &state.textured_model)
	gfx.model_unload(dev, &state.unlit_model)
	gfx.sampler_destroy(dev, state.sampler)
	gfx.pipeline_destroy(dev, state.textured_pipeline)
	gfx.pipeline_destroy(dev, state.unlit_pipeline)
	free(state)
}
