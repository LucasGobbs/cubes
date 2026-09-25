package main

import "core:fmt"
import "core:log"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:strings"

import sdl "vendor:sdl3"
import stbi "vendor:stb/image"

DEBUG :: true
PLATFORM :: "METAL"
Vec3 :: [3]f32
Vec2 :: [2]f32
WHITE :: sdl.FColor{1.0, 1.0, 1.0, 1.0}
key_down: #sparse[sdl.Scancode]bool
VertexData :: struct {
	position: Vec3,
	color:    sdl.FColor,
	uv:       [2]f32,
}

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
	uploader := Uploader {
		gfx = &gfx,
	}
	model := model_load_from_obj(&gfx, "static/ship-large.obj", "static/colormap.png")
	model_upload_to_gpu(&model, &gfx, &uploader)
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


	sampler := sdl.CreateGPUSampler(gfx.gpu, {})


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
		log.info(key_down[.S])
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
			sdl.BindGPUGraphicsPipeline(render_pass, basic_material_pipeline)
			sdl.BindGPUVertexBuffers(
				render_pass,
				0,
				&(sdl.GPUBufferBinding{buffer = model.vertex_buffer.handle}),
				1,
			)
			sdl.BindGPUIndexBuffer(render_pass, {buffer = model.index_buffer.handle}, ._16BIT)
			sdl.PushGPUVertexUniformData(
				gfx.command_buffer,
				0,
				&uniform_buffer,
				size_of(uniform_buffer),
			)
			sdl.BindGPUFragmentSamplers(
				render_pass,
				0,
				&(sdl.GPUTextureSamplerBinding{texture = model.texture.handle, sampler = sampler}),
				1,
			)
			sdl.DrawGPUIndexedPrimitives(render_pass, u32(model.index_buffer.size), 1, 0, 0, 0)
			sdl.EndGPURenderPass(render_pass)
		}

		gfx_end_frame(&gfx)

	}
}
