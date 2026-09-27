package main
import "core:c"
import "core:strings"
import glove "glove"
import glove_sdl "glove/adapters/sdl"
import sdl "vendor:sdl3"
Gfx :: struct {
	window:           ^sdl.Window,
	gpu:              ^sdl.GPUDevice,
	window_size:      [2]i32,
	depth_texture:    ^sdl.GPUTexture,

	// Received via sdl.AcquireGPUCommandBuffer and released after sdl.SubmitGPUCommandBuffer (Short lived)
	command_buffer:   ^sdl.GPUCommandBuffer,
	swapchain:        ^sdl.GPUTexture,
	frame_open:       bool,
	inputs:           glove.System,
	renderer:         Renderer,
	last_ticks:       u64,
	running:          bool,

	// Native GPU resources are owned here. Public code carries generation-checked handles.
	buffers:          [dynamic]Buffer,
	buffer_handles:   Handle_Pool,
	textures:         [dynamic]Texture,
	texture_handles:  Handle_Pool,
	samplers:         [dynamic]Sampler,
	sampler_handles:  Handle_Pool,
	pipelines:        [dynamic]Pipeline,
	pipeline_handles: Handle_Pool,
}

Gfx_Game_Create_Proc :: #type proc(gfx: ^Gfx, game_state: rawptr) -> bool

gfx_create :: proc(
	gfx: ^Gfx,
	game_state: rawptr,
	game_create_callback: Gfx_Game_Create_Proc,
	window_title: string = "Game Window Title",
	window_width: int = 1280,
	window_height: int = 780,
) -> bool {
	ok := sdl.Init({.VIDEO}); assert(ok)
	window := sdl.CreateWindow(
		strings.clone_to_cstring(window_title, context.temp_allocator),
		c.int(window_width),
		c.int(window_height),
		{.ALWAYS_ON_TOP, .MOUSE_GRABBED},
	); assert(window != nil)
	gpu := sdl.CreateGPUDevice({.MSL, .SPIRV}, true, nil); assert(gpu != nil)
	ok = sdl.ClaimWindowForGPUDevice(gpu, window); assert(ok)
	window_size: [2]i32
	ok = sdl.GetWindowSize(window, &window_size.x, &window_size.y); assert(ok)
	ok = sdl.SetWindowRelativeMouseMode(window, true); assert(ok)
	ok = sdl.SetWindowMouseGrab(window, true); assert(ok)
	depth_texture := sdl.CreateGPUTexture(
		gpu,
		{
			format = .D32_FLOAT,
			usage = {.DEPTH_STENCIL_TARGET},
			width = u32(window_size.x),
			height = u32(window_size.y),
			layer_count_or_depth = 1,
			num_levels = 1,
		},
	)
	assert(depth_texture != nil)
	gfx.window = window
	gfx.gpu = gpu
	gfx.window_size = window_size
	gfx.depth_texture = depth_texture
	gfx.inputs = glove.system_create(glove_sdl.create())
	gfx.renderer = renderer_create(gfx)
	gfx.last_ticks = sdl.GetTicks()
	gfx.running = true
	return game_create_callback(gfx, game_state)
}

gfx_begin_frame :: proc(gfx: ^Gfx) -> bool {
	gfx.command_buffer = sdl.AcquireGPUCommandBuffer(gfx.gpu)
	assert(gfx.command_buffer != nil)
	gfx.frame_open = true
	ok := sdl.WaitAndAcquireGPUSwapchainTexture(
		gfx.command_buffer,
		gfx.window,
		&gfx.swapchain,
		nil,
		nil,
	); assert(ok)
	return gfx.swapchain != nil
}

gfx_aspect_ratio :: proc(gfx: ^Gfx) -> f32 {
	return f32(gfx.window_size.x) / f32(gfx.window_size.y)
}

gfx_input :: proc(gfx: ^Gfx) -> ^glove.System {
	return &gfx.inputs
}

gfx_camera :: proc(gfx: ^Gfx) -> ^Camera {
	return &gfx.renderer.camera
}

Gfx_Game_Tick_Proc :: #type proc(gfx: ^Gfx, delta_time: f32, game_state: rawptr)

gfx_update :: proc(gfx: ^Gfx, game_state: rawptr, game_tick_callback: Gfx_Game_Tick_Proc) {
	for gfx.running {
		current_ticks := sdl.GetTicks()
		delta_time := f32(current_ticks - gfx.last_ticks) / 1000
		gfx.last_ticks = current_ticks
		event: sdl.Event
		for sdl.PollEvent(&event) {
			if !glove.register_event(&gfx.inputs, &event) && event.type == .QUIT {
				gfx.running = false
			}
		}
		glove.update(&gfx.inputs)
		if !gfx.running do break
		game_tick_callback(gfx, delta_time, game_state)
	}
}

gfx_request_quit :: proc(gfx: ^Gfx) {
	gfx.running = false
}

gfx_render :: proc(gfx: ^Gfx, scene: ^Scene) {
	renderer_begin_frame(&gfx.renderer)
	renderer_render_scene(&gfx.renderer, scene)
	renderer_end_frame(&gfx.renderer)
	free_all(context.temp_allocator)
}
gfx_end_frame :: proc(gfx: ^Gfx) {
	assert(gfx.frame_open && gfx.command_buffer != nil)
	ok := sdl.SubmitGPUCommandBuffer(gfx.command_buffer); assert(ok)
	gfx.command_buffer, gfx.swapchain, gfx.frame_open = nil, nil, false
}

Gfx_Game_Destroy_Proc :: #type proc(gfx: ^Gfx, game_state: rawptr)

gfx_destroy :: proc(gfx: ^Gfx, game_state: rawptr, game_destroy_callback: Gfx_Game_Destroy_Proc) {
	assert(gfx.command_buffer == nil)
	assert(!gfx.frame_open)
	game_destroy_callback(gfx, game_state)
	renderer_destroy(&gfx.renderer)
	glove.system_destroy(&gfx.inputs)
	for slot, index in gfx.pipeline_handles.slots {
		if slot.alive do gfx_pipeline_destroy(gfx, Pipeline_Handle(Resource_Handle{u32(index), slot.generation}))
	}
	for slot, index in gfx.sampler_handles.slots {
		if slot.alive do gfx_sampler_destroy(gfx, Sampler_Handle(Resource_Handle{u32(index), slot.generation}))
	}
	for slot, index in gfx.texture_handles.slots {
		if slot.alive do gfx_texture_destroy(gfx, Texture_Handle(Resource_Handle{u32(index), slot.generation}))
	}
	for slot, index in gfx.buffer_handles.slots {
		if slot.alive do gfx_buffer_destroy(gfx, Buffer_Handle(Resource_Handle{u32(index), slot.generation}))
	}
	delete(gfx.pipelines)
	delete(gfx.samplers)
	delete(gfx.textures)
	delete(gfx.buffers)
	handle_pool_destroy(&gfx.pipeline_handles)
	handle_pool_destroy(&gfx.sampler_handles)
	handle_pool_destroy(&gfx.texture_handles)
	handle_pool_destroy(&gfx.buffer_handles)

	if gfx.depth_texture != nil {
		sdl.ReleaseGPUTexture(gfx.gpu, gfx.depth_texture)
	}
	if gfx.gpu != nil && gfx.window != nil {
		sdl.ReleaseWindowFromGPUDevice(gfx.gpu, gfx.window)
	}
	if gfx.gpu != nil {
		sdl.DestroyGPUDevice(gfx.gpu)
	}
	if gfx.window != nil {
		sdl.DestroyWindow(gfx.window)
	}

	sdl.Quit()
	gfx^ = {}
}
