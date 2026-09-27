package main

import "core:log"
import "core:math/linalg"
import input "input"
import loader "loader"
import sdl "vendor:sdl3"
DEBUG :: true
PLATFORM :: "METAL"
Vec3 :: [3]f32


main :: proc() {
	context.logger = log.create_console_logger()
	sdl.SetLogPriorities(.VERBOSE)

	gfx := gfx_init()
	defer gfx_destroy(&gfx)

	inputs := input.system_create(input.sdl_adapter())
	defer input.system_destroy(&inputs)

	move_action := input.add_axis_2d(&inputs, "player.move")
	quit_action := input.add_button(&inputs, "app.quit")

	input.bind_button_axis_2d(
		&inputs,
		move_action,
		{up = .W, down = .S, left = .A, right = .D, normalize = true},
	)

	input.bind_key(&inputs, quit_action, .ESCAPE)

	renderer := renderer_init(&gfx)
	defer renderer_destroy(&renderer)

	uploader := Uploader {
		gfx = &gfx,
	}
	defer uploader_destroy(&uploader)

	imported_model := loader.model_import_from_obj("static/ship-large.obj", "static/colormap.png")
	model := model_create(
		&gfx,
		&imported_model,
		renderer.default_sampler,
		&renderer.basic_pipeline,
	)
	defer model_destroy(&gfx, &model)

	model_upload_to_gpu(&model, &uploader)
	loader.model_import_destroy(&imported_model)

	scene: Scene
	defer scene_destroy(&scene)

	model_scale := linalg.matrix4_scale_f32({0.4, 0.4, 0.4})
	scene_add_model(&scene, &model, linalg.matrix4_translate_f32({-5, -.5, -12}) * model_scale)
	center_node := scene_add_model(
		&scene,
		&model,
		linalg.matrix4_translate_f32({0, -.5, -12}) * model_scale,
	)
	scene_add_model(&scene, &model, linalg.matrix4_translate_f32({5, -.5, -12}) * model_scale)

	camera := camera_create(
		position = Vec3{0, 0, 3.0},
		target = Vec3{},
		projection = linalg.matrix4_perspective(
			linalg.to_radians(f32(70)),
			f32(gfx.window_size.x) / f32(gfx.window_size.y),
			0.1,
			1000,
		),
	)
	mouse_sensitivity := linalg.to_radians(f32(0.1))
	rotation_speed := linalg.to_radians(f32(90))
	rotation := f32(0)

	last_ticks := sdl.GetTicks()
	main_loop: for {
		current_ticks := sdl.GetTicks()
		delta_time := f32(current_ticks - last_ticks) / 1000
		last_ticks = sdl.GetTicks()

		event: sdl.Event
		for sdl.PollEvent(&event) {
			if !input.register_event(&inputs, &event) && event.type == .QUIT {
				break main_loop
			}
		}

		input.update(&inputs)
		if input.pressed(&inputs, quit_action) do break main_loop

		look_delta := input.mouse_delta(&inputs)
		camera_rotate(&camera, look_delta.x * mouse_sensitivity, -look_delta.y * mouse_sensitivity)

		move := input.axis_2d(&inputs, move_action)
		move_direction := camera.direction * move.y + camera.right * move.x
		move_velocity: f32 = 5.0

		if move_direction != {} {
			camera.position += move_direction * move_velocity * delta_time
		}

		has_swapchain := gfx_begin_frame(&gfx)

		rotation += rotation_speed * delta_time

		scene.nodes[center_node].transform =
			linalg.matrix4_translate_f32({0, -.5, -12}) *
			linalg.matrix4_rotate_f32(rotation, {0, 1, 0}) *
			model_scale

		if has_swapchain {
			for &node in scene.nodes {
				renderer_submit_model(&renderer, node.model, node.transform)
			}

			renderer_begin_pass(&renderer, camera_view_projection(&camera))
			renderer_flush(&renderer)
			renderer_end_pass(&renderer)
		}

		gfx_end_frame(&gfx)
		free_all(context.temp_allocator)
	}

}
