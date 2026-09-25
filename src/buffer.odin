package main
import "core:slice"
import sdl "vendor:sdl3"
// Buffer
Buffer :: struct {
	// Handle is created by sdl.CreateGPUBuffer
	handle:                ^sdl.GPUBuffer,
	length:                u32,
	size:                  u32,
	usage:                 sdl.GPUBufferUsageFlags,

	// Temporary data waiting to be sended to GPU
	_temporary_raw_data:   []byte,
	_raw_data_is_submited: bool,
}

buffer_create_from_bytes :: proc(gfx: ^Gfx, data: []$T, usage: sdl.GPUBufferUsageFlag) -> Buffer {
	bytes := slice.to_bytes(data)
	byte_size := u32(len(data) * size_of(data[0]))

	buffer := buffer_create(gfx, byte_size, usage)
	buffer._temporary_raw_data = bytes

	return buffer
}
buffer_create :: proc(gfx: ^Gfx, size: u32, usage: sdl.GPUBufferUsageFlag) -> Buffer {
	handle := sdl.CreateGPUBuffer(gfx.gpu, {usage = {usage}, size = size})
	return {handle = handle, size = size, usage = {usage}, _raw_data_is_submited = false}
}


buffer_destroy :: proc(gfx: ^Gfx, buffer: ^Buffer) {
	sdl.ReleaseGPUBuffer(gfx.gpu, buffer.handle)
}
