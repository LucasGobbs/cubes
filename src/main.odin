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
load_shader :: proc(
	$filepath: string,
	gpu_device: ^sdl.GPUDevice,
	stage: sdl.GPUShaderStage,
	num_uniform_buffers: u32,
	num_samplers: u32,
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
			num_samplers = num_samplers,
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
	vert_shader := load_shader("../shaders/generated/triangle.vert.msl", gpu_device, .VERTEX, 1, 0)
	frag_shader := load_shader(
		"../shaders/generated/triangle.frag.msl",
		gpu_device,
		.FRAGMENT,
		0,
		1,
	)

	img_size: [2]i32
	pixels := stbi.load(
		"static/muddy_ground.jpg",
		&img_size.x,
		&img_size.y,
		nil,
		4,
	); assert(pixels != nil)
	pixels_byte_size := img_size.x * img_size.y * 4
	texture := sdl.CreateGPUTexture(
		gpu_device,
		{
			format = .R8G8B8A8_UNORM,
			usage = {.SAMPLER},
			width = u32(img_size.x),
			height = u32(img_size.y),
			layer_count_or_depth = 1,
			num_levels = 1,
		},
	)

	VertexData :: struct {
		position: Vec3,
		color:    sdl.FColor,
		uv:       [2]f32,
	}
	WHITE :: sdl.FColor{1.0, 1.0, 1.0, 1.0}


	obj := obj_load("./static/ship-large.obj")
	vertices: []VertexData = make([]VertexData, len(obj.faces))
	indices: []u16 = make([]u16, len(obj.faces))
	for face, i in obj.faces {
		vertices[i] = {
			position = obj.positions[face.pos],
			color    = WHITE,
			uv       = obj.uv[face.uv],
		}
		indices[i] = u16(i)
	}
	obj_destroy(&obj)

	num_indices := len(indices)

	vertices_byte_size := len(vertices) * size_of(vertices[0])
	indices_byte_size := len(indices) * size_of(indices[0])


	vertex_buffer := sdl.CreateGPUBuffer(
		gpu_device,
		{usage = {.VERTEX}, size = u32(vertices_byte_size)},
	)
	index_buffer := sdl.CreateGPUBuffer(
		gpu_device,
		{usage = {.INDEX}, size = u32(indices_byte_size)},
	)

	transfer_buffer := sdl.CreateGPUTransferBuffer(
		gpu_device,
		{usage = .UPLOAD, size = u32(vertices_byte_size + indices_byte_size)},
	)

	texture_transfer_buffer := sdl.CreateGPUTransferBuffer(
		gpu_device,
		{usage = .UPLOAD, size = u32(pixels_byte_size)},
	)

	transfer_mem := transmute([^]byte)sdl.MapGPUTransferBuffer(gpu_device, transfer_buffer, false)
	mem.copy(transfer_mem, raw_data(vertices), vertices_byte_size)
	mem.copy(transfer_mem[vertices_byte_size:], raw_data(indices), indices_byte_size)

	texture_transfer_mem := sdl.MapGPUTransferBuffer(gpu_device, texture_transfer_buffer, false)
	mem.copy(texture_transfer_mem, pixels, int(pixels_byte_size))

	sdl.UnmapGPUTransferBuffer(gpu_device, transfer_buffer)
	delete(vertices)
	delete(indices)
	sdl.UnmapGPUTransferBuffer(gpu_device, texture_transfer_buffer)
	copy_command_buffer := sdl.AcquireGPUCommandBuffer(gpu_device)

	copy_pass := sdl.BeginGPUCopyPass(copy_command_buffer)
	sdl.UploadToGPUBuffer(
		copy_pass,
		{transfer_buffer = transfer_buffer},
		{buffer = vertex_buffer, size = u32(vertices_byte_size)},
		false,
	)
	sdl.UploadToGPUBuffer(
		copy_pass,
		{transfer_buffer = transfer_buffer, offset = u32(vertices_byte_size)},
		{buffer = index_buffer, size = u32(indices_byte_size)},
		false,
	)
	sdl.UploadToGPUTexture(
		copy_pass,
		{transfer_buffer = texture_transfer_buffer},
		{texture = texture, w = u32(img_size.x), h = u32(img_size.y), d = 1},
		false,
	)
	sdl.EndGPUCopyPass(copy_pass)

	ok = sdl.SubmitGPUCommandBuffer(copy_command_buffer); assert(ok)
	sdl.ReleaseGPUTransferBuffer(gpu_device, transfer_buffer)
	sdl.ReleaseGPUTransferBuffer(gpu_device, texture_transfer_buffer)

	sampler := sdl.CreateGPUSampler(gpu_device, {})
	vertex_attrs := []sdl.GPUVertexAttribute {
		{location = 0, format = .FLOAT3, offset = u32(offset_of(VertexData, position))},
		{location = 1, format = .FLOAT4, offset = u32(offset_of(VertexData, color))},
		{location = 2, format = .FLOAT2, offset = u32(offset_of(VertexData, uv))},
	}


	pipeline := sdl.CreateGPUGraphicsPipeline(
		gpu_device,
		{
			vertex_shader = vert_shader,
			fragment_shader = frag_shader,
			primitive_type = .TRIANGLELIST,
			vertex_input_state = {
				num_vertex_buffers = 1,
				vertex_buffer_descriptions = &(sdl.GPUVertexBufferDescription {
						slot = 0,
						pitch = size_of(VertexData),
					}),
				num_vertex_attributes = u32(len(vertex_attrs)),
				vertex_attributes = raw_data(vertex_attrs),
			},
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
			sdl.BindGPUVertexBuffers(
				render_pass,
				0,
				&(sdl.GPUBufferBinding{buffer = vertex_buffer}),
				1,
			)
			sdl.BindGPUIndexBuffer(render_pass, {buffer = index_buffer}, ._16BIT)
			sdl.PushGPUVertexUniformData(
				command_buffer,
				0,
				&uniform_buffer,
				size_of(uniform_buffer),
			)
			sdl.BindGPUFragmentSamplers(
				render_pass,
				0,
				&(sdl.GPUTextureSamplerBinding{texture = texture, sampler = sampler}),
				1,
			)
			sdl.DrawGPUPrimitives(render_pass, u32(num_indices), 1, 0, 0)
			sdl.DrawGPUIndexedPrimitives(render_pass, u32(num_indices), 1, 0, 0, 0)
			sdl.EndGPURenderPass(render_pass)
		}

		ok = sdl.SubmitGPUCommandBuffer(command_buffer); assert(ok)

	}
}
