package main
import "core:mem"
import "core:strings"
import sdl "vendor:sdl3"
import stbi "vendor:stb/image"
Model :: struct {
	// mesh:    Mesh,
	// texture: Texture,
	vertex_buffer: Buffer,
	index_buffer:  Buffer,
	texture:       Texture,
}

model_load_from_obj :: proc(gfx: ^Gfx, mesh_file: string, texture_file: string) -> Model {
	obj := obj_load(mesh_file)
	defer obj_destroy(&obj)
	vertexes, indexes := obj_unwrap_buffers(&obj)
	vertex_buffer := buffer_create_from_bytes(gfx, vertexes, .VERTEX)
	index_buffer := buffer_create_from_bytes(gfx, indexes, .INDEX)
	texture := texture_load_from_file(gfx, texture_file)

	return {vertex_buffer = vertex_buffer, index_buffer = index_buffer, texture = texture}
}
model_upload_to_gpu :: proc(model: ^Model, gfx: ^Gfx, uploader: ^Uploader) {
	uploader_begin(uploader)
	uploader_upload_buffer(uploader, &model.vertex_buffer)
	uploader_upload_buffer(uploader, &model.index_buffer)
	uploader_upload_texture(uploader, &model.texture)
	uploader_flush_blocking(uploader)
}

// model_upload_to_gpu :: proc(uploader: ^Uploader) {}
