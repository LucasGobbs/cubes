package loader


ImageFormat :: enum {
	RGBA8_UNORM,
}
ImportedMesh :: struct {
	// Owned CPU memory. Never allocate with context.temp_allocator.
	vertices: []VertexData,
	indices:  []u16,
	layout:   VertexLayout,
}

ImageData :: struct {
	// Owned CPU memory. Copy stb_image output into this slice.
	pixels: []byte,
	width:  u32,
	height: u32,
	format: ImageFormat,
}

ImportedModel :: struct {
	mesh:  ImportedMesh,
	image: ImageData,
}

model_import_from_obj :: proc(mesh_file, texture_file: string) -> ImportedModel {
	obj := obj_load(mesh_file)
	defer obj_destroy(&obj)

	vertices, indices := obj_unwrap_buffers(&obj)
	return {
		mesh = {
			vertices = vertices,
			indices  = indices,
			layout   = .POS_COLOR_UV,
		},
		image = image_load(texture_file),
	}
}

model_import_destroy :: proc(model: ^ImportedModel) {
	delete(model.mesh.vertices)
	delete(model.mesh.indices)
	image_destroy(&model.image)
	model^ = {}
}
