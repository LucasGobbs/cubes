package gfx
import "core:c"
import "core:log"
import "core:strings"
import sdl "vendor:sdl3"
Device :: struct {
	window:                   ^sdl.Window,
	gpu:                      ^sdl.GPUDevice,
	window_size:              [2]i32,

	// Received via sdl.AcquireGPUCommandBuffer and released after sdl.SubmitGPUCommandBuffer (Short lived)
	command_buffer:           ^sdl.GPUCommandBuffer,
	swapchain:                ^sdl.GPUTexture,
	frame_open:               bool,
	renderer:                 Renderer,

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

	// Open resource scopes (scope.odin). scope_paused > 0 keeps renderer-owned creations out of them.
	scopes:                   [dynamic][dynamic]Scope_Entry,
	scope_draw_marks:         [dynamic]int, // draws length at each scope_begin
	unscoped_entries:         [dynamic]Scope_Entry, // scope_defer outside any scope
	scope_paused:             int,

	// Scene draws (draw.odin). scope_end truncates the ones added inside its scope.
	draws:                    [dynamic]Draw,
}

create :: proc(
	gfx_ctx: ^Device,
	title: string = "cubes",
	width: int = 1280,
	height: int = 780,
	fullscreen: bool = false, // sized from the desktop mode; window_size is read once, here
	resizable: bool = false, // host reacts to WINDOW_PIXEL_SIZE_CHANGED when set
	cursor: bool = false, // true = free system cursor (no relative mouse mode, no grab)
) -> bool {
	ok := sdl.Init({.VIDEO}); assert(ok)
	flags := sdl.WindowFlags{.ALWAYS_ON_TOP, .MOUSE_GRABBED}
	if resizable do flags += {.RESIZABLE}
	w, h := c.int(width), c.int(height)
	if fullscreen {
		mode := sdl.GetDesktopDisplayMode(sdl.GetPrimaryDisplay())
		assert(mode != nil)
		w, h = mode.w, mode.h
		flags += {.FULLSCREEN}
	}
	window := sdl.CreateWindow(
		strings.clone_to_cstring(title, context.temp_allocator),
		w,
		h,
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
	ok = sdl.SetWindowRelativeMouseMode(window, !cursor); assert(ok)
	ok = sdl.SetWindowMouseGrab(window, !cursor); assert(ok)
	gfx_ctx.window = window
	gfx_ctx.gpu = gpu
	gfx_ctx.window_size = window_size
	gfx_ctx.renderer = renderer_create(gfx_ctx)
	_ = renderer_set_msaa(&gfx_ctx.renderer, true) // on by default where supported
	return true
}

begin_frame :: proc(gfx_ctx: ^Device) -> bool {
	gfx_ctx.command_buffer = sdl.AcquireGPUCommandBuffer(gfx_ctx.gpu)
	assert(gfx_ctx.command_buffer != nil)
	gfx_ctx.frame_open = true
	ok := sdl.WaitAndAcquireGPUSwapchainTexture(
		gfx_ctx.command_buffer,
		gfx_ctx.window,
		&gfx_ctx.swapchain,
		nil,
		nil,
	); assert(ok)
	return gfx_ctx.swapchain != nil
}

aspect_ratio :: proc(gfx_ctx: ^Device) -> f32 {
	return f32(gfx_ctx.window_size.x) / f32(gfx_ctx.window_size.y)
}

// Present mode: .VSYNC (SDL default, caps FPS at display refresh),
// .IMMEDIATE (uncapped, may tear), .MAILBOX (uncapped without tearing where
// supported). Falls back to vsync when the driver rejects the mode.
// Keeps whatever composition create() managed to set (SDR_LINEAR when supported).
swapchain_composition :: proc(gfx_ctx: ^Device) -> sdl.GPUSwapchainComposition {
	if sdl.WindowSupportsGPUSwapchainComposition(gfx_ctx.gpu, gfx_ctx.window, .SDR_LINEAR) do return .SDR_LINEAR
	return .SDR
}

set_present_mode :: proc(gfx_ctx: ^Device, mode: sdl.GPUPresentMode) {
	if sdl.WindowSupportsGPUPresentMode(gfx_ctx.gpu, gfx_ctx.window, mode) {
		_ = sdl.SetGPUSwapchainParameters(gfx_ctx.gpu, gfx_ctx.window, swapchain_composition(gfx_ctx), mode)
	}
}

camera :: proc(gfx_ctx: ^Device) -> ^Camera {
	return &gfx_ctx.renderer.camera
}

model_load :: proc(gfx_ctx: ^Device, desc: Renderer_Load_Desc) -> Model {
	return renderer_load(&gfx_ctx.renderer, desc)
}

model_unload :: proc(gfx_ctx: ^Device, model: ^Model) {
	renderer_unload(&gfx_ctx.renderer, model)
}

end_frame :: proc(gfx_ctx: ^Device) {
	assert(gfx_ctx.frame_open && gfx_ctx.command_buffer != nil)
	ok := sdl.SubmitGPUCommandBuffer(gfx_ctx.command_buffer); assert(ok)
	gfx_ctx.command_buffer, gfx_ctx.swapchain, gfx_ctx.frame_open = nil, nil, false
}

destroy :: proc(gfx_ctx: ^Device) {
	assert(gfx_ctx.command_buffer == nil)
	assert(!gfx_ctx.frame_open)
	assert(len(gfx_ctx.scopes) == 0, "gfx.destroy with open scope; host must scope_end first")
	#reverse for entry in gfx_ctx.unscoped_entries do scope_run(gfx_ctx, entry)
	delete(gfx_ctx.unscoped_entries)
	delete(gfx_ctx.scopes)
	delete(gfx_ctx.scope_draw_marks)
	delete(gfx_ctx.draws)
	renderer_destroy(&gfx_ctx.renderer)
	for slot, index in gfx_ctx.pipeline_handles.slots {
		if slot.alive do pipeline_destroy(gfx_ctx, Pipeline_Handle(Resource_Handle{u32(index), slot.generation}))
	}
	for slot, index in gfx_ctx.compute_pipeline_handles.slots {
		if slot.alive do compute_pipeline_destroy(gfx_ctx, Compute_Pipeline_Handle(Resource_Handle{u32(index), slot.generation}))
	}
	for slot, index in gfx_ctx.sampler_handles.slots {
		if slot.alive do sampler_destroy(gfx_ctx, Sampler_Handle(Resource_Handle{u32(index), slot.generation}))
	}
	for slot, index in gfx_ctx.texture_handles.slots {
		if slot.alive do texture_destroy(gfx_ctx, Texture_Handle(Resource_Handle{u32(index), slot.generation}))
	}
	for slot, index in gfx_ctx.buffer_handles.slots {
		if slot.alive do buffer_destroy(gfx_ctx, Buffer_Handle(Resource_Handle{u32(index), slot.generation}))
	}
	delete(gfx_ctx.pipelines)
	delete(gfx_ctx.compute_pipelines)
	delete(gfx_ctx.samplers)
	delete(gfx_ctx.textures)
	delete(gfx_ctx.buffers)
	handle_pool_destroy(&gfx_ctx.pipeline_handles)
	handle_pool_destroy(&gfx_ctx.compute_pipeline_handles)
	handle_pool_destroy(&gfx_ctx.sampler_handles)
	handle_pool_destroy(&gfx_ctx.texture_handles)
	handle_pool_destroy(&gfx_ctx.buffer_handles)

	if gfx_ctx.gpu != nil && gfx_ctx.window != nil {
		sdl.ReleaseWindowFromGPUDevice(gfx_ctx.gpu, gfx_ctx.window)
	}
	if gfx_ctx.gpu != nil {
		sdl.DestroyGPUDevice(gfx_ctx.gpu)
	}
	if gfx_ctx.window != nil {
		sdl.DestroyWindow(gfx_ctx.window)
	}

	sdl.Quit()
	gfx_ctx^ = {}
}
