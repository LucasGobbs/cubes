package gfx
import input "../input"
import input_sdl "../input/adapters/sdl"
import "core:c"
import "core:log"
import "core:strings"
import sdl "vendor:sdl3"
Device :: struct {
	window:                   ^sdl.Window,
	gpu:                      ^sdl.GPUDevice,
	window_size:              [2]i32,
	using clock:              Clock,

	// Received via sdl.AcquireGPUCommandBuffer and released after sdl.SubmitGPUCommandBuffer (Short lived)
	command_buffer:           ^sdl.GPUCommandBuffer,
	swapchain:                ^sdl.GPUTexture,
	frame_open:               bool,
	inputs:           input.System,
	renderer:         Renderer,
	running:          bool,

	// Called for every SDL event after input processing; used by overlays
	// (editor UI) that need raw events without owning the event loop.
	event_hook:       Gfx_Event_Hook,
	event_hook_data:  rawptr,

	// Native GPU resources are owned here. Public code carries generation-checked handles.
	buffers:                  [dynamic]Buffer,
	buffer_handles:           Handle_Pool,
	textures:                 [dynamic]Texture,
	texture_handles:          Handle_Pool,
	samplers:                 [dynamic]Sampler,
	sampler_handles:          Handle_Pool,
	pipelines:                [dynamic]Pipeline,
	pipeline_handles:         Handle_Pool,
	compute_pipelines:        [dynamic]Compute_Pipeline,
	compute_pipeline_handles: Handle_Pool,
}

Gfx_Game_Create_Proc :: #type proc(dev: ^Device, game_state: rawptr) -> bool

create :: proc(
	dev: ^Device,
	game_state: rawptr,
	game_create_callback: Gfx_Game_Create_Proc,
	window_title: string = "Game Window Title",
	window_width: int = 1280,
	window_height: int = 780,
	fullscreen: bool = false, // sized from the desktop mode; window_size is read once, here
) -> bool {
	ok := sdl.Init({.VIDEO}); assert(ok)
	flags := sdl.WindowFlags{.ALWAYS_ON_TOP, .MOUSE_GRABBED}
	width, height := c.int(window_width), c.int(window_height)
	if fullscreen {
		mode := sdl.GetDesktopDisplayMode(sdl.GetPrimaryDisplay())
		assert(mode != nil)
		width, height = mode.w, mode.h
		flags += {.FULLSCREEN}
	}
	window := sdl.CreateWindow(
		strings.clone_to_cstring(window_title, context.temp_allocator),
		width,
		height,
		flags,
	); assert(window != nil)
	gpu := sdl.CreateGPUDevice({.MSL, .SPIRV}, true, nil); assert(gpu != nil)
	ok = sdl.ClaimWindowForGPUDevice(gpu, window); assert(ok)
	// SDR_LINEAR gives an *_SRGB swapchain: shaders output linear color and the
	// hardware encodes on write. Must be set before renderer_create, which
	// derives scene_color's format from the swapchain.
	if sdl.WindowSupportsGPUSwapchainComposition(gpu, window, .SDR_LINEAR) {
		ok = sdl.SetGPUSwapchainParameters(gpu, window, .SDR_LINEAR, .IMMEDIATE); assert(ok) // uncapped: vsync would hide performance
	} else {
		log.warn("swapchain SDR_LINEAR unsupported: colors will not be gamma-correct")
	}
	log.infof("swapchain format: %v", sdl.GetGPUSwapchainTextureFormat(gpu, window))
	window_size: [2]i32
	ok = sdl.GetWindowSize(window, &window_size.x, &window_size.y); assert(ok)
	ok = sdl.SetWindowRelativeMouseMode(window, true); assert(ok)
	ok = sdl.SetWindowMouseGrab(window, true); assert(ok)
	dev.window = window
	dev.gpu = gpu
	dev.window_size = window_size
	dev.inputs = input.system_create(input_sdl.create())
	dev.renderer = renderer_create(dev)
	_ = renderer_set_msaa(&dev.renderer, true) // on by default where supported

	dev.running = true
	return game_create_callback(dev, game_state)
}

begin_frame :: proc(dev: ^Device) -> bool {
	dev.command_buffer = sdl.AcquireGPUCommandBuffer(dev.gpu)
	assert(dev.command_buffer != nil)
	dev.frame_open = true
	ok := sdl.WaitAndAcquireGPUSwapchainTexture(
		dev.command_buffer,
		dev.window,
		&dev.swapchain,
		nil,
		nil,
	); assert(ok)
	return dev.swapchain != nil
}

aspect_ratio :: proc(dev: ^Device) -> f32 {
	return f32(dev.window_size.x) / f32(dev.window_size.y)
}

// Present mode: .VSYNC (SDL default, caps FPS at display refresh),
// .IMMEDIATE (uncapped, may tear), .MAILBOX (uncapped without tearing where
// supported). Falls back to vsync when the driver rejects the mode.
// Keeps whatever composition create() managed to set (SDR_LINEAR when supported).
swapchain_composition :: proc(dev: ^Device) -> sdl.GPUSwapchainComposition {
	if sdl.WindowSupportsGPUSwapchainComposition(dev.gpu, dev.window, .SDR_LINEAR) do return .SDR_LINEAR
	return .SDR
}

set_present_mode :: proc(dev: ^Device, mode: sdl.GPUPresentMode) {
	if sdl.WindowSupportsGPUPresentMode(dev.gpu, dev.window, mode) {
		_ = sdl.SetGPUSwapchainParameters(dev.gpu, dev.window, swapchain_composition(dev), mode)
	}
}

gfx_input :: proc(dev: ^Device) -> ^input.System {
	return &dev.inputs
}

Gfx_Event_Hook :: #type proc(event: ^sdl.Event, user_data: rawptr)

gfx_set_event_hook :: proc(dev: ^Device, hook: Gfx_Event_Hook, user_data: rawptr) {
	dev.event_hook = hook
	dev.event_hook_data = user_data
}

camera :: proc(dev: ^Device) -> ^Camera {
	return &dev.renderer.camera
}

model_load :: proc(dev: ^Device, desc: Renderer_Load_Desc) -> Model {
	return renderer_load(&dev.renderer, desc)
}

model_unload :: proc(dev: ^Device, model: ^Model) {
	renderer_unload(&dev.renderer, model)
}

Gfx_Game_Tick_Proc :: #type proc(dev: ^Device, delta_time: f32, game_state: rawptr)

gfx_update :: proc(dev: ^Device, game_state: rawptr, game_tick_callback: Gfx_Game_Tick_Proc) {
	for dev.running {
		clock_update(dev)
		event: sdl.Event
		for sdl.PollEvent(&event) {
			if !input.register_event(&dev.inputs, &event) && event.type == .QUIT {
				dev.running = false
			}
			if dev.event_hook != nil do dev.event_hook(&event, dev.event_hook_data)
		}
		input.update(&dev.inputs)
		if !dev.running do break
		game_tick_callback(dev, dev.delta, game_state)
		free_all(context.temp_allocator)
	}
}

gfx_request_quit :: proc(dev: ^Device) {
	dev.running = false
}

// Simple frame: scene -> offscreen -> post passes (renderer_set_passes) -> blit
// to screen. For a frame with your own steps, compose renderer_begin_frame,
// renderer_render_scene, renderer_run_post, renderer_present and renderer_end_frame.
scene_extract_proc :: proc(r: ^Renderer, user: rawptr) {
	renderer_extract_scene(r, (^Scene)(user))
}

gfx_render :: proc(dev: ^Device, scene: ^Scene) {
	renderer_render_frame(&dev.renderer, scene_extract_proc, scene)
}
end_frame :: proc(dev: ^Device) {
	assert(dev.frame_open && dev.command_buffer != nil)
	ok := sdl.SubmitGPUCommandBuffer(dev.command_buffer); assert(ok)
	dev.command_buffer, dev.swapchain, dev.frame_open = nil, nil, false
}

Gfx_Game_Destroy_Proc :: #type proc(dev: ^Device, game_state: rawptr)

destroy :: proc(dev: ^Device, game_state: rawptr, game_destroy_callback: Gfx_Game_Destroy_Proc) {
	assert(dev.command_buffer == nil)
	assert(!dev.frame_open)
	game_destroy_callback(dev, game_state)
	renderer_destroy(&dev.renderer)
	input.system_destroy(&dev.inputs)
	for slot, index in dev.pipeline_handles.slots {
		if slot.alive do pipeline_destroy(dev, Pipeline_Handle(Resource_Handle{u32(index), slot.generation}))
	}
	for slot, index in dev.compute_pipeline_handles.slots {
		if slot.alive do compute_pipeline_destroy(dev, Compute_Pipeline_Handle(Resource_Handle{u32(index), slot.generation}))
	}
	for slot, index in dev.sampler_handles.slots {
		if slot.alive do sampler_destroy(dev, Sampler_Handle(Resource_Handle{u32(index), slot.generation}))
	}
	for slot, index in dev.texture_handles.slots {
		if slot.alive do texture_destroy(dev, Texture_Handle(Resource_Handle{u32(index), slot.generation}))
	}
	for slot, index in dev.buffer_handles.slots {
		if slot.alive do buffer_destroy(dev, Buffer_Handle(Resource_Handle{u32(index), slot.generation}))
	}
	delete(dev.pipelines)
	delete(dev.compute_pipelines)
	delete(dev.samplers)
	delete(dev.textures)
	delete(dev.buffers)
	handle_pool_destroy(&dev.pipeline_handles)
	handle_pool_destroy(&dev.compute_pipeline_handles)
	handle_pool_destroy(&dev.sampler_handles)
	handle_pool_destroy(&dev.texture_handles)
	handle_pool_destroy(&dev.buffer_handles)

	if dev.gpu != nil && dev.window != nil {
		sdl.ReleaseWindowFromGPUDevice(dev.gpu, dev.window)
	}
	if dev.gpu != nil {
		sdl.DestroyGPUDevice(dev.gpu)
	}
	if dev.window != nil {
		sdl.DestroyWindow(dev.window)
	}

	sdl.Quit()
	dev^ = {}
}
