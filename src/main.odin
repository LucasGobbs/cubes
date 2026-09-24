package main

import "core:fmt"
import "core:log"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:strings"
import sdl "vendor:sdl3"

DEBUG :: true
PLATFORM :: "METAL"

// vert_code := #load("../shaders/generated/triangle.vert.msl")
// frag_code := #load("../shaders/generated/triangle.frag.msl")
// format := sdl.GPUShaderFormat{.MSL}

// if strings.starts_with(string(sdl.GetGPUDeviceDriver(r.device)), "vulkan") {
// 	vert_code = #load("../shaders/generated/triangle.vert.spv")
// 	frag_code = #load("../shaders/generated/triangle.frag.spv")
// 	format = {.SPIRV}
// }

// vert_shader := load_shader(vert_code, format, .VERTEX, "vertexMain")
// frag_shader := load_shader(frag_code, format, .FRAGMENT, "pixelMain")

load_shader :: proc(
	$filepath: string,
	gpu_device: ^sdl.GPUDevice,
	stage: sdl.GPUShaderStage,
	num_uniform_buffers: u32,
) -> ^sdl.GPUShader {
	shader_code := #load(filepath)
	shader := sdl.CreateGPUShader(
		gpu_device,
		{
			code = raw_data(shader_code),
			code_size = len(shader_code),
			entrypoint = stage == .VERTEX ? "vertexMain" : "pixelMain",
			format = {.MSL},
			stage = stage,
			num_uniform_buffers = num_uniform_buffers,
		},
	)
	if shader == nil {
		log.error("Error creating shader: ", filepath, string(sdl.GetError()))
	}

	return shader
}
main :: proc() {
	context.logger = log.create_console_logger()
	sdl.SetLogPriorities(.VERBOSE)

	ok := sdl.Init({.VIDEO}); assert(ok)
	window := sdl.CreateWindow("Odin SDL3 gpu", 1280, 780, {}); assert(window != nil)
	gpu_device := sdl.CreateGPUDevice({.MSL, .SPIRV}, DEBUG, nil); assert(gpu_device != nil)
	ok = sdl.ClaimWindowForGPUDevice(gpu_device, window); assert(ok)

	rotation_speed := linalg.to_radians(f32(90))
	rotation := f32(0)
	window_size: [2]i32
	ok = sdl.GetWindowSize(window, &window_size.x, &window_size.y); assert(ok)
	aspect := window_size
	projection := linalg.matrix4_perspective(
		linalg.to_radians(f32(70)),
		f32(window_size.x) / f32(window_size.y),
		0.000001,
		1000,
	)
	model := linalg.matrix4_rotate_f32(rotation, {0, 1, 0})
	UniformBuffer :: struct #max_field_align(16) {
		mvp: matrix[4, 4]f32,
	}
	vert_shader := load_shader("../shaders/generated/triangle.vert.msl", gpu_device, .VERTEX, 1)
	frag_shader := load_shader("../shaders/generated/triangle.frag.msl", gpu_device, .FRAGMENT, 0)

	pipeline := sdl.CreateGPUGraphicsPipeline(
		gpu_device,
		{
			vertex_shader = vert_shader,
			fragment_shader = frag_shader,
			primitive_type = .TRIANGLELIST,
			target_info = {
				num_color_targets = 1,
				color_target_descriptions = &(sdl.GPUColorTargetDescription {
						format = sdl.GetGPUSwapchainTextureFormat(gpu_device, window),
					}),
			},
		},
	)
	sdl.ReleaseGPUShader(gpu_device, vert_shader)
	sdl.ReleaseGPUShader(gpu_device, frag_shader)
	last_ticks := sdl.GetTicks()
	main_loop: for {
		current_ticks := sdl.GetTicks()
		delta_time := f32(current_ticks - last_ticks) / 1000
		last_ticks = sdl.GetTicks()

		event: sdl.Event
		for sdl.PollEvent(&event) {
			#partial switch event.type {
			case .QUIT:
				break main_loop
			case .KEY_DOWN:
				if event.key.scancode == .ESCAPE do break main_loop
			}
		}

		command_buffer := sdl.AcquireGPUCommandBuffer(gpu_device)
		swapchain_tex: ^sdl.GPUTexture
		ok = sdl.WaitAndAcquireGPUSwapchainTexture(
			command_buffer,
			window,
			&swapchain_tex,
			nil,
			nil,
		); assert(ok)

		rotation += rotation_speed * delta_time
		model =
			linalg.matrix4_translate_f32({0, 0, -5}) *
			linalg.matrix4_rotate_f32(rotation, {0, 1, 0})
		uniform_buffer := UniformBuffer {
			mvp = projection * model,
		}
		if swapchain_tex != nil {
			color_target := sdl.GPUColorTargetInfo {
				texture     = swapchain_tex,
				load_op     = .CLEAR,
				clear_color = {0.2, 0.2, 0.5, 1},
				store_op    = .STORE,
			}
			render_pass := sdl.BeginGPURenderPass(command_buffer, &color_target, 1, nil)
			sdl.BindGPUGraphicsPipeline(render_pass, pipeline)
			sdl.PushGPUVertexUniformData(
				command_buffer,
				0,
				&uniform_buffer,
				size_of(uniform_buffer),
			)
			sdl.DrawGPUPrimitives(render_pass, 3, 1, 0, 0)
			sdl.EndGPURenderPass(render_pass)
		}

		ok = sdl.SubmitGPUCommandBuffer(command_buffer); assert(ok)

	}
}
