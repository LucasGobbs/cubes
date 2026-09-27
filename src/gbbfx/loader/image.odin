package loader

import "core:strings"

import stbi "vendor:stb/image"

image_load :: proc(filename: string) -> ImageData {
	image_size: [2]i32
	stbi_pixels := stbi.load(
		strings.clone_to_cstring(filename, context.temp_allocator),
		&image_size.x,
		&image_size.y,
		nil,
		4,
	); assert(stbi_pixels != nil)
	defer stbi.image_free(stbi_pixels)

	pixel_count := int(image_size.x * image_size.y * 4)
	pixels := make([]byte, pixel_count)
	copy(pixels, stbi_pixels[:pixel_count])

	return {
		pixels = pixels,
		width  = u32(image_size.x),
		height = u32(image_size.y),
		format = .RGBA8_UNORM,
	}
}

image_destroy :: proc(image: ^ImageData) {
	delete(image.pixels)
	image^ = {}
}
