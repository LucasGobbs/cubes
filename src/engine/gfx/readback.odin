package gfx

import "core:mem"
import sdl "vendor:sdl3"

// Frame capture for offline rendering. When enabled, renderer_run_post copies the frame's color
// before the After_Post overlays (stats, scene title, transition) draw into it, so those never reach
// the readback. Pixels are RGBA8 sRGB, the encoding the swapchain would show.
Readback :: struct {
	enabled:  bool, // set by the host: capture every frame
	captured: bool, // copy recorded into this frame's command buffer
	ready:    bool, // pixels hold a finished frame not yet taken by readback_frame
	w, h:     u32,
	texture:  Texture_Handle,
	transfer: ^sdl.GPUTransferBuffer,
	pixels:   []u8,
}

// Records a copy of `source` into the frame command buffer. Called by renderer_run_post between passes.
readback_capture :: proc(renderer: ^Renderer, source: Texture_Handle) {
	rb := &renderer.readback
	if !rb.enabled do return
	gfx_ctx := renderer.gfx_ctx
	src := texture_get(gfx_ctx, source)
	if rb.w != src.width || rb.h != src.height {
		readback_destroy(renderer)
		gfx_ctx.scope_paused += 1
		defer gfx_ctx.scope_paused -= 1
		rb.w, rb.h = src.width, src.height
		rb.texture = texture_create_with_usage(gfx_ctx, rb.w, rb.h, .R8G8B8A8_UNORM_SRGB, {.COLOR_TARGET})
		rb.transfer = sdl.CreateGPUTransferBuffer(gfx_ctx.gpu, {usage = .DOWNLOAD, size = rb.w * rb.h * 4})
		rb.pixels = make([]u8, rb.w * rb.h * 4)
	}
	// The blit encodes linear post output to sRGB the same way the swapchain present does.
	dst := texture_get(gfx_ctx, rb.texture)
	sdl.BlitGPUTexture(
		gfx_ctx.command_buffer,
		{
			source = {texture = src.handle, w = src.width, h = src.height},
			destination = {texture = dst.handle, w = rb.w, h = rb.h},
			load_op = .DONT_CARE,
			filter = .NEAREST,
		},
	)
	copy := sdl.BeginGPUCopyPass(gfx_ctx.command_buffer)
	sdl.DownloadFromGPUTexture(copy, {texture = dst.handle, w = rb.w, h = rb.h, d = 1}, {transfer_buffer = rb.transfer})
	sdl.EndGPUCopyPass(copy)
	rb.captured = true
}

// Called after the frame is submitted: waits for the GPU and copies the pixels to the CPU.
readback_finish :: proc(renderer: ^Renderer) {
	rb := &renderer.readback
	if !rb.captured do return
	rb.captured = false
	gpu := renderer.gfx_ctx.gpu
	assert(sdl.WaitForGPUIdle(gpu))
	mapped := sdl.MapGPUTransferBuffer(gpu, rb.transfer, false)
	mem.copy(raw_data(rb.pixels), mapped, len(rb.pixels))
	sdl.UnmapGPUTransferBuffer(gpu, rb.transfer)
	rb.ready = true
}

// Pixels of the last rendered frame, RGBA8 sRGB, top row first. Each frame is returned once; the slice
// is valid until the next frame. nil when no frame was captured since the last call.
readback_frame :: proc(gfx_ctx: ^Device, renderer: ^Renderer) -> (pixels: []u8, w, h: u32) {
	rb := &renderer.readback
	if !rb.ready do return nil, 0, 0
	rb.ready = false
	return rb.pixels, rb.w, rb.h
}

readback_destroy :: proc(renderer: ^Renderer) {
	rb := &renderer.readback
	if rb.transfer != nil do sdl.ReleaseGPUTransferBuffer(renderer.gfx_ctx.gpu, rb.transfer)
	if rb.w != 0 do texture_destroy(renderer.gfx_ctx, rb.texture)
	if rb.pixels != nil do delete(rb.pixels)
	// Release resources only: `enabled` belongs to the host, not to the buffers.
	rb.transfer, rb.texture, rb.pixels, rb.w, rb.h = nil, {}, nil, 0, 0
	rb.captured, rb.ready = false, false
}
