// Key 3 — Models: every OBJ in static/ on a textured ground plane, each
// rotating at its own speed.
package main

import gbbfx "gbbfx"
import defaults "gbbfx/defaults"
import glove "glove"
import "core:math/linalg"

MODEL_PATHS :: [4]string {
	"static/boat-tug-a.obj",
	"static/ship-cargo-a.obj",
	"static/ship-large.obj",
	"static/ship-small-ghost.obj",
}

Models_State :: struct {
	pipeline:        gbbfx.Pipeline_Handle,
	sampler:         gbbfx.Sampler_Handle,
	models:          [4]gbbfx.Model,
	ground_texture:  gbbfx.Texture_Handle,
	ground_material: gbbfx.Material,
	ground_mesh:     gbbfx.Mesh,
	scene:           gbbfx.Scene,
	entities:        [4]int,
	rotation:        f32,

	move_action:     glove.Axis_2D_Action,
	boost_action:    glove.Button_Action,
	up_action:       glove.Button_Action,
	down_action:     glove.Button_Action,
}

models_scene :: proc() -> Scene {
	return {name = "Models", create = models_create, tick = models_tick, destroy = models_destroy}
}

models_create :: proc(demo: ^Scene, gfx: ^gbbfx.Gfx) -> bool {
	state := new(Models_State)
	demo.state = state
	camera_reset(gfx, {0, 2, 4})

	inputs := gbbfx.gfx_input(gfx)
	state.move_action = glove.add_axis_2d(inputs, "models.move")
	state.boost_action = glove.add_button(inputs, "models.boost")
	state.up_action = glove.add_button(inputs, "models.up")
	state.down_action = glove.add_button(inputs, "models.down")
	glove.bind_button_axis_2d(
		inputs,
		state.move_action,
		{up = .W, down = .S, left = .A, right = .D, normalize = true},
	)
	glove.bind_key(inputs, state.boost_action, .LSHIFT)
	glove.bind_key(inputs, state.up_action, .SPACE)
	glove.bind_key(inputs, state.down_action, .LCTRL)

	state.pipeline = defaults.create_textured_pipeline(gfx)
	state.sampler = gbbfx.gfx_sampler_create(gfx)

	for path, index in MODEL_PATHS {
		state.models[index] = load_textured_model(
			gfx,
			path,
			"static/colormap.png",
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
	state.ground_texture = load_texture(gfx, "static/muddy_ground.jpg")
	state.ground_material = gbbfx.material_create(state.pipeline)
	defaults.bind_textured_material(&state.ground_material, state.ground_texture, state.sampler)
	tiling :: f32(40)
	ground_vertices := [4]gbbfx.VertexData {
		{position = {-100, -1, -100}, color = {1, 1, 1, 1}, uv = {0, 0}},
		{position = {100, -1, -100}, color = {1, 1, 1, 1}, uv = {tiling, 0}},
		{position = {100, -1, 100}, color = {1, 1, 1, 1}, uv = {tiling, tiling}},
		{position = {-100, -1, 100}, color = {1, 1, 1, 1}, uv = {0, tiling}},
	}
	ground_indices := [6]u16{0, 2, 1, 0, 3, 2}
	state.ground_mesh = gbbfx.mesh_create(gfx, ground_vertices[:], ground_indices[:])
	gbbfx.mesh_upload(&gfx.renderer, &state.ground_mesh)
	ground := gbbfx.scene_add_entity(&state.scene)
	ground_entity := gbbfx.scene_entity(&state.scene, ground)
	gbbfx.entity_add_renderable(ground_entity, &state.ground_mesh, &state.ground_material)
	return true
}

models_tick :: proc(demo: ^Scene, gfx: ^gbbfx.Gfx, delta_time: f32) {
	state := cast(^Models_State)demo.state

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

	state.rotation += delta_time
	for entity, index in state.entities {
		gbbfx.entity_set_rotation_euler(
			gbbfx.scene_entity(&state.scene, entity),
			0,
			state.rotation * (0.4 + 0.3 * f32(index)),
			0,
		)
	}
	gbbfx.gfx_render(gfx, &state.scene)
}

models_destroy :: proc(demo: ^Scene, gfx: ^gbbfx.Gfx) {
	state := cast(^Models_State)demo.state
	gbbfx.scene_destroy(&state.scene)
	gbbfx.mesh_destroy(gfx, &state.ground_mesh)
	gbbfx.material_destroy(&state.ground_material)
	gbbfx.gfx_texture_destroy(gfx, state.ground_texture)
	for &model in state.models do gbbfx.gfx_unload(gfx, &model)
	gbbfx.gfx_sampler_destroy(gfx, state.sampler)
	gbbfx.gfx_pipeline_destroy(gfx, state.pipeline)
	free(state)
}
