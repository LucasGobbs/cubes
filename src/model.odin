package main
import loader "loader"
import sdl "vendor:sdl3"
#assert(size_of(VertexData) == size_of(loader.VertexData))
#assert(offset_of(VertexData, position) == offset_of(loader.VertexData, position))
#assert(offset_of(VertexData, color) == offset_of(loader.VertexData, color))
#assert(offset_of(VertexData, uv) == offset_of(loader.VertexData, uv))

Model :: struct {
	mesh:     Mesh,
	material: Material,
}

model_create :: proc(
	gfx: ^Gfx,
	imported: ^loader.ImportedModel,
	sampler: ^sdl.GPUSampler,
	pipeline: ^Pipeline,
) -> Model {
	mesh := Mesh {
		vertex_buffer = buffer_create_from_bytes(gfx, imported.mesh.vertices, .VERTEX),
		index_buffer  = buffer_create_from_bytes(gfx, imported.mesh.indices, .INDEX),
		num_indices   = u32(len(imported.mesh.indices)),
		index_size    = ._16BIT,
		layout        = .POS_COLOR_UV,
	}

	texture := texture_create(
		gfx,
		imported.image.width,
		imported.image.height,
		image_format_to_gpu(imported.image.format),
		.SAMPLER,
	)
	texture._temporary_raw_data = imported.image.pixels

	material := Material {
		texture  = texture,
		pipeline = pipeline,
		sampler  = sampler,
	}

	return {mesh = mesh, material = material}
}

image_format_to_gpu :: proc(format: loader.ImageFormat) -> sdl.GPUTextureFormat {
	assert(format == .RGBA8_UNORM)
	return .R8G8B8A8_UNORM
}
model_upload_to_gpu :: proc(model: ^Model, uploader: ^Uploader) {
	uploader_begin(uploader)
	uploader_upload_buffer(uploader, &model.mesh.vertex_buffer)
	uploader_upload_buffer(uploader, &model.mesh.index_buffer)
	uploader_upload_texture(uploader, &model.material.texture)
	uploader_flush_blocking(uploader)
	model.mesh.vertex_buffer._temporary_raw_data = nil
	model.mesh.index_buffer._temporary_raw_data = nil
	model.material.texture._temporary_raw_data = nil
}

model_destroy :: proc(gfx: ^Gfx, model: ^Model) {
	mesh_destroy(gfx, &model.mesh)
	material_destroy(gfx, &model.material)
	model^ = {}
}
