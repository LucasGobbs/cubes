package main

import sdl "vendor:sdl3"

Texture :: struct {
	handle:              ^sdl.GPUTexture,
	format:              sdl.GPUTextureFormat,
	usage:               sdl.GPUTextureUsageFlag,
	width, height:       u32,
	_temporary_raw_data: []byte,
}

gfx_texture_create :: proc(
	gfx: ^Gfx,
	width, height: u32,
	format: sdl.GPUTextureFormat,
	usage: sdl.GPUTextureUsageFlag,
) -> Texture_Handle {
	resource := Texture {
		handle = sdl.CreateGPUTexture(
			gfx.gpu,
			{
				format = format,
				usage = {usage},
				width = width,
				height = height,
				layer_count_or_depth = 1,
				num_levels = 1,
			},
		),
		format = format,
		usage  = usage,
		width  = width,
		height = height,
	}
	assert(resource.handle != nil)
	handle := Texture_Handle(handle_pool_acquire(&gfx.texture_handles))
	index := Resource_Handle(handle).index
	if int(index) == len(gfx.textures) {
		append(&gfx.textures, resource)
	} else {
		gfx.textures[index] = resource
	}
	return handle
}

gfx_texture_get :: proc(gfx: ^Gfx, handle: Texture_Handle) -> ^Texture {
	raw := Resource_Handle(handle)
	assert(handle_pool_contains(&gfx.texture_handles, raw), "stale texture handle")
	return &gfx.textures[raw.index]
}

gfx_texture_destroy :: proc(gfx: ^Gfx, handle: Texture_Handle) {
	raw := Resource_Handle(handle)
	if !handle_pool_contains(&gfx.texture_handles, raw) do return
	resource := &gfx.textures[raw.index]
	if resource.handle != nil do sdl.ReleaseGPUTexture(gfx.gpu, resource.handle)
	resource^ = {}
	assert(handle_pool_release(&gfx.texture_handles, raw))
}
