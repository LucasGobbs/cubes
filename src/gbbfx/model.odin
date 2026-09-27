package gbbfx

import loader "loader"
import sdl "vendor:sdl3"

#assert(size_of(VertexData) == size_of(loader.VertexData))
#assert(offset_of(VertexData, position) == offset_of(loader.VertexData, position))
#assert(offset_of(VertexData, color) == offset_of(loader.VertexData, color))
#assert(offset_of(VertexData, uv) == offset_of(loader.VertexData, uv))

Model :: struct {
	mesh:          Mesh,
	material:      Material,
	owned_texture: Texture_Handle,
}

model_create :: proc(
	gfx: ^Gfx,
	imported: ^loader.ImportedModel,
	pipeline: Pipeline_Handle,
) -> Model {
	model := Model {
		mesh     = mesh_create(gfx, imported.mesh.vertices, imported.mesh.indices),
		material = material_create(pipeline),
	}
	if len(imported.image.pixels) > 0 {
		model.owned_texture = gfx_texture_create(
			gfx,
			imported.image.width,
			imported.image.height,
			image_format_to_gpu(imported.image.format),
			.SAMPLER,
		)
		gfx_texture_get(gfx, model.owned_texture)._temporary_raw_data = imported.image.pixels
	}
	return model
}

model_texture :: proc(model: ^Model) -> Texture_Handle {
	return model.owned_texture
}

image_format_to_gpu :: proc(format: loader.ImageFormat) -> sdl.GPUTextureFormat {
	assert(format == .RGBA8_UNORM)
	return .R8G8B8A8_UNORM
}

model_upload_to_gpu :: proc(model: ^Model, uploader: ^Uploader) {
	uploader_begin(uploader)
	uploader_upload_buffer(uploader, model.mesh.vertex_buffer)
	uploader_upload_buffer(uploader, model.mesh.index_buffer)
	if Resource_Handle(model.owned_texture).generation != 0 {
		uploader_upload_texture(uploader, model.owned_texture)
	}
	uploader_flush_blocking(uploader)
	gfx_buffer_get(uploader.gfx, model.mesh.vertex_buffer)._temporary_raw_data = nil
	gfx_buffer_get(uploader.gfx, model.mesh.index_buffer)._temporary_raw_data = nil
	if Resource_Handle(model.owned_texture).generation != 0 {
		gfx_texture_get(uploader.gfx, model.owned_texture)._temporary_raw_data = nil
	}
}

model_destroy :: proc(gfx: ^Gfx, model: ^Model) {
	mesh_destroy(gfx, &model.mesh)
	material_destroy(&model.material)
	if Resource_Handle(model.owned_texture).generation != 0 {
		gfx_texture_destroy(gfx, model.owned_texture)
	}
	model^ = {}
}
