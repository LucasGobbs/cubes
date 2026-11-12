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

gfx_buffer_create_from_bytes :: proc(
	dev: ^Device,
	data: []$T,
	usage: sdl.GPUBufferUsageFlag,
) -> Buffer_Handle {
	handle := gfx_buffer_create(dev, u32(len(data) * size_of(T)), usage)
	resource := gfx_buffer_get(dev, handle)
	resource.length = u32(len(data))
	resource._temporary_raw_data = slice.to_bytes(data)
	return handle
}

// Stages new contents for an existing buffer, reusing the GPU allocation
// when it is large enough. On growth the old buffer is released after a GPU
// idle wait, so it is safe to call between frames without a retire queue.
// The data is not on the GPU until the buffer goes through the Uploader.
gfx_buffer_stage :: proc(
	dev: ^Device,
	handle: Buffer_Handle,
	data: []$T,
	usage: sdl.GPUBufferUsageFlag,
) -> Buffer_Handle {
	size := u32(len(data) * size_of(T))
	resource := gfx_buffer_get(dev, handle)
	if resource.size >= size && resource.usage == {usage} {
		resource.length = u32(len(data))
		resource._temporary_raw_data = slice.to_bytes(data)
		return handle
	}
	ok := sdl.WaitForGPUIdle(dev.gpu)
	assert(ok)
	gfx_buffer_destroy(dev, handle)
	return gfx_buffer_create_from_bytes(dev, data, usage)
}

gfx_buffer_create :: proc(dev: ^Device, size: u32, usage: sdl.GPUBufferUsageFlag) -> Buffer_Handle {
	resource := Buffer {
		handle = sdl.CreateGPUBuffer(dev.gpu, {usage = {usage}, size = size}),
		size   = size,
		usage  = {usage},
	}
	assert(resource.handle != nil)
	handle := Buffer_Handle(handle_pool_acquire(&dev.buffer_handles))
	index := Resource_Handle(handle).index
	if int(index) == len(dev.buffers) {
		append(&dev.buffers, resource)
	} else {
		dev.buffers[index] = resource
	}
	return handle
}

gfx_buffer_get :: proc(dev: ^Device, handle: Buffer_Handle) -> ^Buffer {
	raw := Resource_Handle(handle)
	assert(handle_pool_contains(&dev.buffer_handles, raw), "stale buffer handle")
	return &dev.buffers[raw.index]
}

gfx_buffer_destroy :: proc(dev: ^Device, handle: Buffer_Handle) {
	raw := Resource_Handle(handle)
	if !handle_pool_contains(&dev.buffer_handles, raw) do return
	resource := &dev.buffers[raw.index]
	if resource.handle != nil do sdl.ReleaseGPUBuffer(dev.gpu, resource.handle)
	resource^ = {}
	assert(handle_pool_release(&dev.buffer_handles, raw))
}
