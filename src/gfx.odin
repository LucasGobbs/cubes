package main
import "core:mem"
import "core:strings"
import sdl "vendor:sdl3"
import stbi "vendor:stb/image"
Gfx :: struct {
	window:         ^sdl.Window,
	gpu:            ^sdl.GPUDevice,
	window_size:    [2]i32,
	depth_texture:  ^sdl.GPUTexture,

	// Received via sdl.AcquireGPUCommandBuffer and released after sdl.SubmitGPUCommandBuffer (Short lived)
	command_buffer: ^sdl.GPUCommandBuffer,
	swapchain:      ^sdl.GPUTexture,
	frame_open:     bool,
}


gfx_init :: proc() -> Gfx {
	ok := sdl.Init({.VIDEO}); assert(ok)
	window := sdl.CreateWindow(
		"Odin SDL3 gfx.gpu",
		1280,
		780,
		{.ALWAYS_ON_TOP, .MOUSE_GRABBED},
	); assert(window != nil)
	gpu := sdl.CreateGPUDevice({.MSL, .SPIRV}, DEBUG, nil); assert(gpu != nil)
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
	return {window = window, gpu = gpu, window_size = window_size, depth_texture = depth_texture}

}

gfx_begin_frame :: proc(gfx: ^Gfx) -> bool {
	gfx.command_buffer = sdl.AcquireGPUCommandBuffer(gfx.gpu)
	ok := sdl.WaitAndAcquireGPUSwapchainTexture(
		gfx.command_buffer,
		gfx.window,
		&gfx.swapchain,
		nil,
		nil,
	); assert(ok)
	return gfx.swapchain != nil
}
gfx_end_frame :: proc(gfx: ^Gfx) {
	ok := sdl.SubmitGPUCommandBuffer(gfx.command_buffer); assert(ok)
	gfx.command_buffer, gfx.swapchain, gfx.frame_open = nil, nil, false
}

gfx_destroy :: proc(gfx: ^Gfx) {
	assert(gfx.command_buffer == nil)
	assert(!gfx.frame_open)

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
