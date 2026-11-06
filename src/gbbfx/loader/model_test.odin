package loader

import "core:testing"

// Run from the repository root (make test): asset paths are relative to it.

@(test)
gltf_import_bakes_node_transforms_and_external_texture :: proc(t: ^testing.T) {
	model, ok := model_import_from_gltf("static/models/ship-large.glb")
	testing.expect(t, ok)
	defer model_import_destroy(&model)

	testing.expect(t, len(model.mesh.indices) > 0 && len(model.mesh.indices) % 3 == 0)
	highest: f32
	for index in model.mesh.indices do testing.expect(t, int(index) < len(model.mesh.vertices))
	for vertex in model.mesh.vertices do highest = max(highest, vertex.position.y)
	// The flag-c child node sits 8.2 units above the hull; its own mesh is
	// near the origin, so this only holds when node transforms are applied.
	testing.expect(t, highest > 8)
	testing.expect_value(t, model.image.width, u32(512)) // Textures/colormap.png
}

@(test)
gltf_import_decodes_embedded_image :: proc(t: ^testing.T) {
	model, ok := model_import_from_gltf("static/models/stanford_dragon_pbr.glb")
	testing.expect(t, ok)
	defer model_import_destroy(&model)

	testing.expect(t, model.image.width > 1) // embedded JPEG via bufferView
	testing.expect(t, len(model.mesh.indices) > 0)
}

@(test)
gltf_import_without_texture_falls_back_to_white :: proc(t: ^testing.T) {
	model, ok := model_import_from_gltf("static/models/sphere.glb")
	testing.expect(t, ok)
	defer model_import_destroy(&model)
	testing.expect_value(t, model.image.width, u32(1))
	testing.expect_value(t, model.image.pixels[0], u8(255))
}
