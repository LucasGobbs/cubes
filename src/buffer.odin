package main

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

gfx_buffer_create_from_bytes :: proc(
	gfx: ^Gfx,
	data: []$T,
	usage: sdl.GPUBufferUsageFlag,
) -> Buffer_Handle {
	handle := gfx_buffer_create(gfx, u32(len(data) * size_of(T)), usage)
	resource := gfx_buffer_get(gfx, handle)
	resource.length = u32(len(data))
	resource._temporary_raw_data = slice.to_bytes(data)
	return handle
}

gfx_buffer_create :: proc(gfx: ^Gfx, size: u32, usage: sdl.GPUBufferUsageFlag) -> Buffer_Handle {
	resource := Buffer {
		handle = sdl.CreateGPUBuffer(gfx.gpu, {usage = {usage}, size = size}),
		size   = size,
		usage  = {usage},
	}
	assert(resource.handle != nil)
	handle := Buffer_Handle(handle_pool_acquire(&gfx.buffer_handles))
	index := Resource_Handle(handle).index
	if int(index) == len(gfx.buffers) {
		append(&gfx.buffers, resource)
	} else {
		gfx.buffers[index] = resource
	}
	return handle
}

gfx_buffer_get :: proc(gfx: ^Gfx, handle: Buffer_Handle) -> ^Buffer {
	raw := Resource_Handle(handle)
	assert(handle_pool_contains(&gfx.buffer_handles, raw), "stale buffer handle")
	return &gfx.buffers[raw.index]
}

gfx_buffer_destroy :: proc(gfx: ^Gfx, handle: Buffer_Handle) {
	raw := Resource_Handle(handle)
	if !handle_pool_contains(&gfx.buffer_handles, raw) do return
	resource := &gfx.buffers[raw.index]
	if resource.handle != nil do sdl.ReleaseGPUBuffer(gfx.gpu, resource.handle)
	resource^ = {}
	assert(handle_pool_release(&gfx.buffer_handles, raw))
}
