package main

import "core:log"
import "core:math/linalg"
import glove "glove"

Game_State :: struct {
	assets:            Renderer_Assets,
	scene:             Scene,
	center_node:       int,
	move_action:       glove.Axis_2D_Action,
	quit_action:       glove.Button_Action,
	mouse_sensitivity: f32,
	rotation_speed:    f32,
	rotation:          f32,
	model_scale:       matrix[4, 4]f32,
}

main :: proc() {
	context.logger = log.create_console_logger()
	game: Game_State
	gfx: Gfx
	created := gfx_create(&gfx, rawptr(&game), game_create)
	assert(created)
	defer gfx_destroy(&gfx, rawptr(&game), game_destroy)
	gfx_update(&gfx, rawptr(&game), game_tick)
}

game_create :: proc(gfx: ^Gfx, raw_game: rawptr) -> bool {
	game := cast(^Game_State)raw_game
	inputs := gfx_input(gfx)
	game.move_action = glove.add_axis_2d(inputs, "player.move")
	game.quit_action = glove.add_button(inputs, "app.quit")
	glove.bind_button_axis_2d(
		inputs,
		game.move_action,
		{up = .W, down = .S, left = .A, right = .D, normalize = true},
	)
	glove.bind_key(inputs, game.quit_action, .ESCAPE)

	game.assets = renderer_load(
		&gfx.renderer,
		{
			model_path = "static/ship-large.obj",
			texture_path = "static/colormap.png",
			unlit_tint = {0.15, 0.85, 0.3, 1},
		},
	)
	game.model_scale = linalg.matrix4_scale_f32({0.4, 0.4, 0.4})
	scene_add_model(
		&game.scene,
		&game.assets.textured_model,
		linalg.matrix4_translate_f32({-5, -.5, -12}) * game.model_scale,
	)
	game.center_node = scene_add_model(
		&game.scene,
		&game.assets.textured_model,
		linalg.matrix4_translate_f32({0, -.5, -12}) * game.model_scale,
	)
	scene_add_model(
		&game.scene,
		&game.assets.unlit_model,
		linalg.matrix4_translate_f32({5, -.5, -12}) * game.model_scale,
	)
	game.mouse_sensitivity = linalg.to_radians(f32(0.1))
	game.rotation_speed = linalg.to_radians(f32(90))
	return true
}

game_tick :: proc(gfx: ^Gfx, delta_time: f32, raw_game: rawptr) {
	game := cast(^Game_State)raw_game
	inputs := gfx_input(gfx)
	if glove.pressed(inputs, game.quit_action) {
		gfx_request_quit(gfx)
		return
	}

	camera := gfx_camera(gfx)
	look_delta := glove.mouse_delta(inputs)
	camera_rotate(
		camera,
		look_delta.x * game.mouse_sensitivity,
		-look_delta.y * game.mouse_sensitivity,
	)
	move := glove.axis_2d(inputs, game.move_action)
	move_direction := camera.direction * move.y + camera.right * move.x
	if move_direction != {} {
		camera.position += move_direction * f32(5) * delta_time
	}

	game.rotation += game.rotation_speed * delta_time
	game.scene.nodes[game.center_node].transform =
		linalg.matrix4_translate_f32({0, -.5, -12}) *
		linalg.matrix4_rotate_f32(game.rotation, {0, 1, 0}) *
		game.model_scale
	gfx_render(gfx, &game.scene)
}

game_destroy :: proc(gfx: ^Gfx, raw_game: rawptr) {
	game := cast(^Game_State)raw_game
	scene_destroy(&game.scene)
	renderer_unload(&gfx.renderer, &game.assets)
	game^ = {}
}
