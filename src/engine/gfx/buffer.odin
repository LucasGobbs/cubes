package gfx

import "core:slice"
import sdl "vendor:sdl3"

Buffer :: struct {
	handle:                ^sdl.GPUBuffer,
	length:                u32,
	size:                  u32,
	usage:                 sdl.GPUBufferUsageFlags,
	_temporary_raw_data:   []byte,
	_raw_data_is_submited: bool,
}

buffer_create_from_bytes :: proc(
	gfx_ctx: ^Device,
	data: []$T,
	usage: sdl.GPUBufferUsageFlag,
) -> Buffer_Handle {
	handle := buffer_create(gfx_ctx, u32(len(data) * size_of(T)), usage)
	resource := buffer_get(gfx_ctx, handle)
	resource.length = u32(len(data))
	resource._temporary_raw_data = slice.to_bytes(data)
	return handle
}

// Stages new contents for an existing buffer, reusing the GPU allocation
// when it is large enough. On growth the old buffer is released after a GPU
// idle wait, so it is safe to call between frames without a retire queue.
// The data is not on the GPU until the buffer goes through the Uploader.
buffer_stage :: proc(
	gfx_ctx: ^Device,
	handle: Buffer_Handle,
	data: []$T,
	usage: sdl.GPUBufferUsageFlag,
) -> Buffer_Handle {
	size := u32(len(data) * size_of(T))
	resource := buffer_get(gfx_ctx, handle)
	if resource.size >= size && resource.usage == {usage} {
		resource.length = u32(len(data))
		resource._temporary_raw_data = slice.to_bytes(data)
		return handle
	}
	ok := sdl.WaitForGPUIdle(gfx_ctx.gpu)
	assert(ok)
	buffer_destroy(gfx_ctx, handle)
	return buffer_create_from_bytes(gfx_ctx, data, usage)
}

buffer_create :: proc(gfx_ctx: ^Device, size: u32, usage: sdl.GPUBufferUsageFlag) -> Buffer_Handle {
	resource := Buffer {
		handle = sdl.CreateGPUBuffer(gfx_ctx.gpu, {usage = {usage}, size = size}),
		size   = size,
		usage  = {usage},
	}
	assert(resource.handle != nil)
	return buffer_add(gfx_ctx, resource)
}

// Registers a native buffer in the pool. Split out so tests run without a GPU.
buffer_add :: proc(gfx_ctx: ^Device, resource: Buffer) -> Buffer_Handle {
	handle := Buffer_Handle(handle_pool_acquire(&gfx_ctx.buffer_handles))
	index := Resource_Handle(handle).index
	if int(index) == len(gfx_ctx.buffers) {
		append(&gfx_ctx.buffers, resource)
	} else {
		gfx_ctx.buffers[index] = resource
	}
	scope_track(gfx_ctx, .Buffer, Resource_Handle(handle))
	return handle
}

buffer_get :: proc(gfx_ctx: ^Device, handle: Buffer_Handle) -> ^Buffer {
	raw := Resource_Handle(handle)
	assert(handle_pool_contains(&gfx_ctx.buffer_handles, raw), "stale buffer handle")
	return &gfx_ctx.buffers[raw.index]
}

buffer_destroy :: proc(gfx_ctx: ^Device, handle: Buffer_Handle) {
	raw := Resource_Handle(handle)
	if !handle_pool_contains(&gfx_ctx.buffer_handles, raw) do return
	scope_untrack(gfx_ctx, .Buffer, raw)
	resource := &gfx_ctx.buffers[raw.index]
	if resource.handle != nil do sdl.ReleaseGPUBuffer(gfx_ctx.gpu, resource.handle)
	resource^ = {}
	assert(handle_pool_release(&gfx_ctx.buffer_handles, raw))
}
