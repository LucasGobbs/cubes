// Simple scene: one textured ship, one unlit ship, one animated raw quad.
package main

import gbbfx "gbbfx"
import defaults "gbbfx/defaults"
import glove "glove"
import "core:math/linalg"

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
	spinning:          int,
	rotation:          f32,

	move_action:       glove.Axis_2D_Action,
	boost_action:      glove.Button_Action,
	up_action:         glove.Button_Action,
	down_action:       glove.Button_Action,
}

simple_scene :: proc() -> Scene {
	return {name = "Simple", create = simple_create, tick = simple_tick, destroy = simple_destroy}
}

simple_create :: proc(demo: ^Scene, gfx: ^gbbfx.Gfx) -> bool {
	state := new(Simple_State)
	demo.state = state
	camera_reset(gfx)

	inputs := gbbfx.gfx_input(gfx)
	state.move_action = glove.add_axis_2d(inputs, "simple.move")
	state.boost_action = glove.add_button(inputs, "simple.boost")
	state.up_action = glove.add_button(inputs, "simple.up")
	state.down_action = glove.add_button(inputs, "simple.down")
	glove.bind_button_axis_2d(
		inputs,
		state.move_action,
		{up = .W, down = .S, left = .A, right = .D, normalize = true},
	)
	glove.bind_key(inputs, state.boost_action, .LSHIFT)
	glove.bind_key(inputs, state.up_action, .SPACE)
	glove.bind_key(inputs, state.down_action, .LCTRL)

	state.textured_pipeline = defaults.create_textured_pipeline(gfx)
	state.unlit_pipeline = defaults.create_unlit_pipeline(gfx)
	state.sampler = gbbfx.gfx_sampler_create(gfx)

	state.textured_model = load_textured_model(
		gfx,
		"static/ship-large.obj",
		"static/colormap.png",
		state.textured_pipeline,
		state.sampler,
	)
	state.unlit_model = gbbfx.gfx_load(
		gfx,
		{model_path = "static/ship-small-ghost.obj", pipeline = state.unlit_pipeline},
	)
	defaults.set_unlit_color(&state.unlit_model.material, {0.2, 0.8, 0.9, 1})

	state.spinning = gbbfx.scene_add_model(
		&state.scene,
		&state.textured_model,
		{-2.5, -0.5, -10},
		{0.4, 0.4, 0.4},
	)
	gbbfx.scene_add_model(&state.scene, &state.unlit_model, {2.5, -0.5, -10}, {0.4, 0.4, 0.4})

	// Raw geometry: animated quad through the unlit pipeline.
	state.quad_vertices = {
		{position = {-1, -1, 0}, color = {1, 1, 1, 1}, uv = {0, 0}},
		{position = {1, -1, 0}, color = {1, 1, 1, 1}, uv = {1, 0}},
		{position = {1, 1, 0}, color = {1, 1, 1, 1}, uv = {1, 1}},
		{position = {-1, 1, 0}, color = {1, 1, 1, 1}, uv = {0, 1}},
	}
	state.quad_indices = {0, 1, 2, 2, 3, 0}
	state.quad_mesh = gbbfx.mesh_create(gfx, state.quad_vertices[:], state.quad_indices[:])
	gbbfx.mesh_upload(&gfx.renderer, &state.quad_mesh)
	quad := gbbfx.scene_add_entity(&state.scene)
	quad_entity := gbbfx.scene_entity(&state.scene, quad)
	gbbfx.entity_set_position(quad_entity, {0, 1.2, -8})
	gbbfx.entity_add_renderable(quad_entity, &state.quad_mesh, &state.unlit_model.material, .UI)
	return true
}

simple_tick :: proc(demo: ^Scene, gfx: ^gbbfx.Gfx, delta_time: f32) {
	state := cast(^Simple_State)demo.state

	inputs := gbbfx.gfx_input(gfx)
	camera := gbbfx.gfx_camera(gfx)
	look := glove.mouse_delta(inputs)
	gbbfx.camera_rotate(camera, look.x * 0.1 * linalg.PI / 180, -look.y * 0.1 * linalg.PI / 180)
	move := glove.axis_2d(inputs, state.move_action)
	vertical: f32
	if glove.down(inputs, state.up_action) do vertical += 1
	if glove.down(inputs, state.down_action) do vertical -= 1
	boost: f32 = 1
	if glove.down(inputs, state.boost_action) do boost = 4
	direction := camera.direction * move.y + camera.right * move.x + gbbfx.Vec3{0, vertical, 0}
	if direction != {} do camera.position += direction * f32(5) * boost * delta_time

	state.rotation += linalg.to_radians(f32(60)) * delta_time
	gbbfx.entity_set_rotation_euler(
		gbbfx.scene_entity(&state.scene, state.spinning),
		0,
		state.rotation,
		0,
	)

	state.quad_vertices[2].position.y = 1 + 0.5 * linalg.sin(gfx.time * 2)
	state.quad_vertices[3].position.y = 1 - 0.5 * linalg.sin(gfx.time * 2)
	gbbfx.mesh_update(&gfx.renderer, &state.quad_mesh, state.quad_vertices[:], state.quad_indices[:])

	gbbfx.gfx_render(gfx, &state.scene)
}

simple_destroy :: proc(demo: ^Scene, gfx: ^gbbfx.Gfx) {
	state := cast(^Simple_State)demo.state
	gbbfx.scene_destroy(&state.scene)
	gbbfx.mesh_destroy(gfx, &state.quad_mesh)
	gbbfx.gfx_unload(gfx, &state.textured_model)
	gbbfx.gfx_unload(gfx, &state.unlit_model)
	gbbfx.gfx_sampler_destroy(gfx, state.sampler)
	gbbfx.gfx_pipeline_destroy(gfx, state.textured_pipeline)
	gbbfx.gfx_pipeline_destroy(gfx, state.unlit_pipeline)
	free(state)
}
