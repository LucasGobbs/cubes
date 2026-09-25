package main
import "core:strings"
import sdl "vendor:sdl3"
import stbi "vendor:stb/image"
// Texture
Texture :: struct {
	handle:              ^sdl.GPUTexture,
	// format:        sdl.GPUTextureFormat,
	usage:               sdl.GPUTextureUsageFlag,
	width, height:       u32,
	_temporary_raw_data: []byte,
}

texture_load_from_file :: proc(gfx: ^Gfx, texture_file: string) -> Texture {
	img_size: [2]i32
	pixels := stbi.load(
		strings.clone_to_cstring(texture_file, context.temp_allocator),
		&img_size.x,
		&img_size.y,
		nil,
		4,
	); assert(pixels != nil)

	pixels_byte_size := img_size.x * img_size.y * 4

	texture := texture_create(gfx, u32(img_size.x), u32(img_size.y), .SAMPLER)
	texture._temporary_raw_data = pixels[:pixels_byte_size]

	return texture
}
texture_create :: proc(gfx: ^Gfx, width, height: u32, usage: sdl.GPUTextureUsageFlag) -> Texture {
	handle := sdl.CreateGPUTexture(
		gfx.gpu,
		{
			format = .R8G8B8A8_UNORM,
			usage = {usage},
			width = width,
			height = height,
			layer_count_or_depth = 1,
			num_levels = 1,
		},
	)
	return {handle = handle, usage = usage, width = width, height = height}
}

texture_destroy :: proc(gfx: ^Gfx, texture: ^Texture) {
	sdl.ReleaseGPUTexture(gfx.gpu, texture.handle)
}
