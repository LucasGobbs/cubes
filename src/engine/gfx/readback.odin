package gfx

import "core:mem"
import sdl "vendor:sdl3"

// Frame capture for offline rendering. When enabled, renderer_run_post copies the frame's color
// before the After_Post overlays (stats, scene title, transition) draw into it, so those never reach
// the readback. Pixels are RGBA8 sRGB, the encoding the swapchain would show.
Readback :: struct {
	enabled:   bool, // set by the host: capture every frame
	requested: int,  // frames left in a readback_request capture; 0 when idle
	captured:  bool, // copy recorded into this frame's command buffer
	ready:     bool, // pixels hold a finished frame not yet taken by readback_frame
	w, h:      u32,
	texture:   Texture_Handle,
	transfer:  ^sdl.GPUTransferBuffer,
	pixels:    []u8,
}

// Frames captured per F12. Shortcut: the first copies into fresh buffers read zeros (cause not found),
// so the earlier frames are dropped and the last is kept. Upgrade: find the root cause and use 1.
READBACK_ONE_SHOT_FRAMES :: 4

// Records a copy of `source` into the frame command buffer. Called by renderer_run_post between passes.
readback_capture :: proc(renderer: ^Renderer, source: Texture_Handle) {
	rb := &renderer.readback
	if !rb.enabled && rb.requested == 0 do return
	gfx_ctx := renderer.gfx_ctx
	src := texture_get(gfx_ctx, source)
	if rb.w != src.width || rb.h != src.height do readback_alloc(renderer, src.width, src.height)
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
	if rb.requested > 0 do rb.requested -= 1
}

// Captures the next READBACK_ONE_SHOT_FRAMES frames; readback_frame yields the last one.
readback_request :: proc(renderer: ^Renderer) {
	renderer.readback.requested = READBACK_ONE_SHOT_FRAMES
}

// Allocates the capture buffers for a source of size w x h.
readback_alloc :: proc(renderer: ^Renderer, w, h: u32) {
	gfx_ctx := renderer.gfx_ctx
	rb := &renderer.readback
	readback_destroy(renderer)
	gfx_ctx.scope_paused += 1
	defer gfx_ctx.scope_paused -= 1
	rb.w, rb.h = w, h
	rb.texture = texture_create_with_usage(gfx_ctx, w, h, .R8G8B8A8_UNORM_SRGB, {.COLOR_TARGET})
	rb.transfer = sdl.CreateGPUTransferBuffer(gfx_ctx.gpu, {usage = .DOWNLOAD, size = w * h * 4})
	rb.pixels = make([]u8, w * h * 4)
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
	if !rb.ready || rb.requested > 0 do return nil, 0, 0
	rb.ready = false
	return rb.pixels, rb.w, rb.h
}

// Frees the capture buffers after a one-shot capture; the next request allocates them again.
readback_release :: proc(renderer: ^Renderer) {
	if !renderer.readback.enabled do readback_destroy(renderer)
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
