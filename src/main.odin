package main

import "core:log"
import "core:math/linalg"
import loader "loader"
import sdl "vendor:sdl3"

DEBUG :: true
PLATFORM :: "METAL"
Vec3 :: [3]f32
key_down: #sparse[sdl.Scancode]bool

camera: struct {
	position: Vec3,
	target:   Vec3,
}
main :: proc() {
	context.logger = log.create_console_logger()
	sdl.SetLogPriorities(.VERBOSE)

	gfx := gfx_init()

	camera = {
		position = {0, 0, 3},
		target   = {0, 0, 0},
	}
	basic_material_pipeline := gfx_basic_pipeline(&gfx)
	sampler := sdl.CreateGPUSampler(gfx.gpu, {})
	uploader := Uploader {
		gfx = &gfx,
	}
	imported_model := loader.model_import_from_obj("static/ship-large.obj", "static/colormap.png")
	model := model_create(&gfx, &imported_model, sampler, basic_material_pipeline)
	model_upload_to_gpu(&model, &uploader)
	loader.model_import_destroy(&imported_model)
	rotation_speed := linalg.to_radians(f32(90))
	rotation := f32(0)


	aspect := gfx.window_size
	projection := linalg.matrix4_perspective(
		linalg.to_radians(f32(70)),
		f32(gfx.window_size.x) / f32(gfx.window_size.y),
		0.1,
		1000,
	)
	model_mat := linalg.matrix4_rotate_f32(rotation, {0, 1, 0})
	UniformBuffer :: struct #max_field_align(16) {
		mvp: matrix[4, 4]f32,
	}


	last_ticks := sdl.GetTicks()
	main_loop: for {
		current_ticks := sdl.GetTicks()
		delta_time := f32(current_ticks - last_ticks) / 1000
		last_ticks = sdl.GetTicks()

		event: sdl.Event
		for sdl.PollEvent(&event) {
			free_all(context.temp_allocator)
			#partial switch event.type {
			case .QUIT:
				break main_loop
			case .KEY_DOWN:
				if event.key.scancode == .ESCAPE do break main_loop
				key_down[event.key.scancode] = true
			case .KEY_UP:
				key_down[event.key.scancode] = false
			}
		}
		if key_down[.S] {
			camera.position.z += 5 * delta_time
			camera.target.z += 5 * delta_time
		} else if key_down[.W] {
			camera.position.z -= 5 * delta_time
			camera.target.z -= 5 * delta_time
		}
		if key_down[.A] {
			camera.position.x -= 5 * delta_time
			camera.target.x -= 5 * delta_time
		} else if key_down[.D] {
			camera.position.x += 5 * delta_time
			camera.target.x += 5 * delta_time
		}
		has_swapchain := gfx_begin_frame(&gfx)

		rotation += rotation_speed * delta_time


		view_mat := linalg.matrix4_look_at_f32(camera.position, camera.target, {0, 1, 0})
		model_mat =
			linalg.matrix4_translate_f32({0, -.5, -12}) *
			linalg.matrix4_rotate_f32(rotation, {0, 1, 0}) *
			linalg.matrix4_scale_f32({1, 1, 1})

		uniform_buffer := UniformBuffer {
			mvp = projection * view_mat * model_mat,
		}
		if has_swapchain {
			color_target := sdl.GPUColorTargetInfo {
				texture     = gfx.swapchain,
				load_op     = .CLEAR,
				clear_color = {0.2, 0.2, 0.5, 1},
				store_op    = .STORE,
			}

			depth_target_info := sdl.GPUDepthStencilTargetInfo {
				texture     = gfx.depth_texture,
				load_op     = .CLEAR,
				clear_depth = 1,
				store_op    = .DONT_CARE,
			}

			render_pass := sdl.BeginGPURenderPass(
				gfx.command_buffer,
				&color_target,
				1,
				&depth_target_info,
			)

			sdl.BindGPUGraphicsPipeline(render_pass, model.material.pipeline)
			sdl.BindGPUFragmentSamplers(
				render_pass,
				0,
				&(sdl.GPUTextureSamplerBinding {
						texture = model.material.texture.handle,
						sampler = model.material.sampler,
					}),
				1,
			)

			sdl.PushGPUVertexUniformData(
				gfx.command_buffer,
				0,
				&uniform_buffer,
				size_of(uniform_buffer),
			)

			mesh_draw(&model.mesh, render_pass)
			sdl.EndGPURenderPass(render_pass)
		}

		gfx_end_frame(&gfx)

	}
}
