package gfx

import loader "loader"
import sdl "vendor:sdl3"

#assert(size_of(VertexData) == size_of(loader.VertexData))
#assert(offset_of(VertexData, position) == offset_of(loader.VertexData, position))
#assert(offset_of(VertexData, color) == offset_of(loader.VertexData, color))
#assert(offset_of(VertexData, uv) == offset_of(loader.VertexData, uv))
#assert(offset_of(VertexData, normal) == offset_of(loader.VertexData, normal))
#assert(size_of(SkinnedVertexData) == size_of(loader.SkinnedVertexData))
#assert(offset_of(SkinnedVertexData, position) == offset_of(loader.SkinnedVertexData, position))
#assert(offset_of(SkinnedVertexData, normal) == offset_of(loader.SkinnedVertexData, normal))
#assert(offset_of(SkinnedVertexData, uv) == offset_of(loader.SkinnedVertexData, uv))
#assert(offset_of(SkinnedVertexData, joints) == offset_of(loader.SkinnedVertexData, joints))
#assert(offset_of(SkinnedVertexData, weights) == offset_of(loader.SkinnedVertexData, weights))

Model :: struct {
	mesh:          Mesh,
	material:      Material,
	owned_texture: Texture_Handle,
	// Skinned models own their skin; zero for static models.
	skin:          loader.Skin,
}

model_create :: proc(
	gfx_ctx: ^Device,
	imported: ^loader.ImportedModel,
	pipeline: Pipeline_Handle,
) -> Model {
	model := Model {
		mesh     = mesh_create(gfx_ctx, imported.mesh.vertices, imported.mesh.indices),
		material = material_create(pipeline),
	}
	model.owned_texture = model_texture_create(gfx_ctx, imported.image)
	return model
}

model_texture_create :: proc(gfx_ctx: ^Device, image: loader.ImageData) -> Texture_Handle {
	if len(image.pixels) == 0 do return {}
	// glTF base color textures are sRGB by spec.
	assert(image.format == .RGBA8_UNORM)
	texture := texture_create_rgba8(gfx_ctx, image.width, image.height, srgb = true, mipmaps = true)
	texture_get(gfx_ctx, texture)._temporary_raw_data = image.pixels
	return texture
}

// The skin moves into the model; imported.skin is zeroed so
// skinned_model_destroy does not free it twice.
model_create_skinned :: proc(
	gfx_ctx: ^Device,
	imported: ^loader.ImportedSkinnedModel,
	pipeline: Pipeline_Handle,
) -> Model {
	model := Model {
		mesh     = mesh_create(gfx_ctx, imported.vertices, imported.indices),
		material = material_create(pipeline),
		skin     = imported.skin,
	}
	imported.skin = {}
	model.owned_texture = model_texture_create(gfx_ctx, imported.image)
	return model
}

model_texture :: proc(model: ^Model) -> Texture_Handle {
	return model.owned_texture
}

model_upload_to_gpu :: proc(model: ^Model, uploader: ^Uploader) {
	uploader_begin(uploader)
	uploader_upload_buffer(uploader, model.mesh.vertex_buffer)
	uploader_upload_buffer(uploader, model.mesh.index_buffer)
	if Resource_Handle(model.owned_texture).generation != 0 {
		uploader_upload_texture(uploader, model.owned_texture)
	}
	uploader_flush_blocking(uploader)
	buffer_get(uploader.gfx_ctx, model.mesh.vertex_buffer)._temporary_raw_data = nil
	buffer_get(uploader.gfx_ctx, model.mesh.index_buffer)._temporary_raw_data = nil
	if Resource_Handle(model.owned_texture).generation != 0 {
		texture_get(uploader.gfx_ctx, model.owned_texture)._temporary_raw_data = nil
	}
}

model_destroy :: proc(gfx_ctx: ^Device, model: ^Model) {
	mesh_destroy(gfx_ctx, &model.mesh)
	material_destroy(&model.material)
	loader.skin_destroy(&model.skin)
	if Resource_Handle(model.owned_texture).generation != 0 {
		texture_destroy(gfx_ctx, model.owned_texture)
	}
	model^ = {}
}

// Loads a .glb/.gltf and binds its base color texture to the default
// textured material.
load_textured_model :: proc(
	gfx_ctx: ^Device,
	model_path: string,
	pipeline: Pipeline_Handle,
	sampler: Sampler_Handle,
) -> Model {
	model := model_load(gfx_ctx, {model_path = model_path, pipeline = pipeline})
	bind_textured_material(&model.material, model_texture(&model), sampler)
	return model
}
