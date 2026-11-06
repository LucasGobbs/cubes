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
	); assert(stbi_pixels != nil, "image_load: cannot decode file")
	return image_take_stbi_pixels(stbi_pixels, image_size)
}

// Decodes an encoded PNG/JPEG held in memory (glTF embedded images).
image_load_from_memory :: proc(encoded: []byte) -> (ImageData, bool) {
	image_size: [2]i32
	stbi_pixels := stbi.load_from_memory(
		raw_data(encoded),
		i32(len(encoded)),
		&image_size.x,
		&image_size.y,
		nil,
		4,
	)
	if stbi_pixels == nil do return {}, false
	return image_take_stbi_pixels(stbi_pixels, image_size), true
}

// 1x1 opaque white: lets untextured models flow through textured pipelines,
// where the vertex color (material base color) carries the tint.
image_white :: proc() -> ImageData {
	pixels := make([]byte, 4)
	for &pixel in pixels do pixel = 255
	return {pixels = pixels, width = 1, height = 1, format = .RGBA8_UNORM}
}

// Copies stb output into Odin-owned memory and frees the stb buffer.
@(private = "file")
image_take_stbi_pixels :: proc(stbi_pixels: [^]byte, image_size: [2]i32) -> ImageData {
	defer stbi.image_free(stbi_pixels)
	pixel_count := int(image_size.x * image_size.y * 4)
	pixels := make([]byte, pixel_count)
	copy(pixels, stbi_pixels[:pixel_count])
	return {
		pixels = pixels,
		width = u32(image_size.x),
		height = u32(image_size.y),
		format = .RGBA8_UNORM,
	}
}

image_destroy :: proc(image: ^ImageData) {
	delete(image.pixels)
	image^ = {}
}
