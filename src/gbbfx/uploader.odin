package gbbfx
import "core:mem"
import sdl "vendor:sdl3"
// Uploader
Uploader :: struct {
	gfx:            ^Gfx,

	// Fences ready
	free:           [dynamic]Staging,

	// Fences still submiting to GPU
	pending:        [dynamic]Staging,
	command_buffer: ^sdl.GPUCommandBuffer,
	pass:           ^sdl.GPUCopyPass,
}

// Handles the lifecycle of a transfer buffer usign a Fence
Staging :: struct {
	buffer: ^sdl.GPUTransferBuffer,
	size:   u32,

	// Nil until the submit that consumed this buffer
	fence:  ^sdl.GPUFence,
}


uploader_begin :: proc(uploader: ^Uploader) {
	assert(uploader.pass == nil)
	uploader.command_buffer = sdl.AcquireGPUCommandBuffer(uploader.gfx.gpu)
	uploader.pass = sdl.BeginGPUCopyPass(uploader.command_buffer)
}

uploader_upload_buffer :: proc(uploader: ^Uploader, handle: Buffer_Handle) {
	destination := gfx_buffer_get(uploader.gfx, handle)
	data := destination._temporary_raw_data
	staging := uploader_acquire_staging(uploader, u32(len(data)))

	mapped := sdl.MapGPUTransferBuffer(uploader.gfx.gpu, staging.buffer, false)
	mem.copy(mapped, raw_data(data), len(data))
	sdl.UnmapGPUTransferBuffer(uploader.gfx.gpu, staging.buffer)

	sdl.UploadToGPUBuffer(
		uploader.pass,
		{transfer_buffer = staging.buffer},
		{buffer = destination.handle, size = u32(len(data))},
		false,
	)

	append(&uploader.pending, staging)
}


// texture_transfer_buffer := sdl.CreateGPUTransferBuffer(
// 	gfx.gpu,
// 	{usage = .UPLOAD, size = u32(pixels_byte_size)},
// )
// texture_transfer_mem := sdl.MapGPUTransferBuffer(gfx.gpu, texture_transfer_buffer, false)
// mem.copy(texture_transfer_mem, pixels, int(pixels_byte_size))


uploader_upload_texture :: proc(uploader: ^Uploader, handle: Texture_Handle) {
	destination := gfx_texture_get(uploader.gfx, handle)
	data := destination._temporary_raw_data
	staging := uploader_acquire_staging(uploader, u32(len(data)))

	mapped := sdl.MapGPUTransferBuffer(uploader.gfx.gpu, staging.buffer, false)
	mem.copy(mapped, raw_data(data), len(data))
	sdl.UnmapGPUTransferBuffer(uploader.gfx.gpu, staging.buffer)

	sdl.UploadToGPUTexture(
		uploader.pass,
		{transfer_buffer = staging.buffer},
		{texture = destination.handle, w = destination.width, h = destination.height, d = 1},
		false,
	)

	append(&uploader.pending, staging)
}
uploader_flush :: proc(up: ^Uploader) {
	sdl.EndGPUCopyPass(up.pass)
	fence := sdl.SubmitGPUCommandBufferAndAcquireFence(up.command_buffer)
	for s in up.pending {
		s := s
		s.fence = fence
		append(&up.pending, s)
	}
	clear(&up.pending)
	up.pass, up.command_buffer = nil, nil
}

uploader_flush_blocking :: proc(up: ^Uploader) {
	sdl.EndGPUCopyPass(up.pass)
	fence := sdl.SubmitGPUCommandBufferAndAcquireFence(up.command_buffer)
	fences := [1]^sdl.GPUFence{fence}
	ok := sdl.WaitForGPUFences(up.gfx.gpu, true, &fences[0], 1); assert(ok)
	sdl.ReleaseGPUFence(up.gfx.gpu, fence)
	for &s in up.pending {
		s.fence = nil
		append(&up.free, s)
	}
	clear(&up.pending)
	up.pass, up.command_buffer = nil, nil
}

uploader_collect :: proc(up: ^Uploader) {
	for i := len(up.pending) - 1; i >= 0; i -= 1 {
		s := up.pending[i]
		if !sdl.QueryGPUFence(up.gfx.gpu, s.fence) do continue
		sdl.ReleaseGPUFence(up.gfx.gpu, s.fence)
		s.fence = nil
		append(&up.free, s)
		unordered_remove(&up.pending, i)
	}
}
uploader_acquire_staging :: proc(uploader: ^Uploader, size: u32) -> Staging {
	for stage, idx in uploader.free {
		if stage.size < size do continue
		unordered_remove(&uploader.free, idx)
		return stage
	}
	return Staging {
		buffer = sdl.CreateGPUTransferBuffer(uploader.gfx.gpu, {usage = .UPLOAD, size = size}),
		size = size,
	}
}

uploader_destroy :: proc(up: ^Uploader) {
	assert(up.pass == nil)
	assert(up.command_buffer == nil)
	assert(len(up.pending) == 0)

	for staging in up.free {
		assert(staging.fence == nil)
		if staging.buffer != nil {
			sdl.ReleaseGPUTransferBuffer(up.gfx.gpu, staging.buffer)
		}
	}

	delete(up.free)
	delete(up.pending)
	up^ = {}
}
