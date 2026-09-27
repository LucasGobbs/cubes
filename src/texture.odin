package main
import sdl "vendor:sdl3"
// Texture
Texture :: struct {
	handle:              ^sdl.GPUTexture,
	format:              sdl.GPUTextureFormat,
	usage:               sdl.GPUTextureUsageFlag,
	width, height:       u32,
	_temporary_raw_data: []byte,
}

texture_create :: proc(
	gfx: ^Gfx,
	width, height: u32,
	format: sdl.GPUTextureFormat,
	usage: sdl.GPUTextureUsageFlag,
) -> Texture {
	handle := sdl.CreateGPUTexture(
		gfx.gpu,
		{
			format = format,
			usage = {usage},
			width = width,
			height = height,
			layer_count_or_depth = 1,
			num_levels = 1,
		},
	)
	return {handle = handle, format = format, usage = usage, width = width, height = height}
}

texture_destroy :: proc(gfx: ^Gfx, texture: ^Texture) {
	if texture.handle == nil do return
	sdl.ReleaseGPUTexture(gfx.gpu, texture.handle)
	texture^ = {}
}
