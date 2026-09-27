package main

import loader "loader"
import shader_parameters "shader_parameters"
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

model_mesh_create :: proc(gfx: ^Gfx, imported: ^loader.ImportedModel) -> Mesh {
	return {
		vertex_buffer = gfx_buffer_create_from_bytes(gfx, imported.mesh.vertices, .VERTEX),
		index_buffer = gfx_buffer_create_from_bytes(gfx, imported.mesh.indices, .INDEX),
		num_indices = u32(len(imported.mesh.indices)),
		index_size = ._16BIT,
		layout = .POS_COLOR_UV,
	}
}

model_create_textured :: proc(
	gfx: ^Gfx,
	imported: ^loader.ImportedModel,
	sampler: Sampler_Handle,
	pipeline: Pipeline_Handle,
) -> Model {
	mesh := model_mesh_create(gfx, imported)
	texture := gfx_texture_create(
		gfx,
		imported.image.width,
		imported.image.height,
		image_format_to_gpu(imported.image.format),
		.SAMPLER,
	)
	gfx_texture_get(gfx, texture)._temporary_raw_data = imported.image.pixels

	material := material_create(pipeline)
	material_bind_texture(
		&material,
		shader_parameters.TRIANGLE_FRAGMENT_TEX,
		shader_parameters.TRIANGLE_FRAGMENT_TEX_SAMPLER,
		texture,
		sampler,
	)
	return {mesh = mesh, material = material, owned_texture = texture}
}

model_create_unlit :: proc(
	gfx: ^Gfx,
	imported: ^loader.ImportedModel,
	pipeline: Pipeline_Handle,
	tint: [4]f32,
) -> Model {
	return {mesh = model_mesh_create(gfx, imported), material = material_create(pipeline, tint)}
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
