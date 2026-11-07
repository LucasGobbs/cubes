package loader

import "core:math"
import "core:math/linalg"
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

@(test)
gltf_import_outputs_unit_normals :: proc(t: ^testing.T) {
	// ship-large has child nodes with translation and scale, so a wrong normal
	// matrix would show up as non-unit or flipped normals.
	model, ok := model_import_from_gltf("static/models/ship-large.glb")
	testing.expect(t, ok)
	defer model_import_destroy(&model)

	for vertex in model.mesh.vertices {
		testing.expect(t, abs(linalg.length(vertex.normal) - 1) < 1e-3)
	}
}

@(test)
gltf_normals_point_outward_matching_triangle_winding :: proc(t: ^testing.T) {
	// glTF winding is counter-clockwise outward, so the geometric face normal
	// must agree with the stored vertex normals for nearly every triangle.
	model, ok := model_import_from_gltf("static/models/boat-tug-a.glb")
	testing.expect(t, ok)
	defer model_import_destroy(&model)

	agree, total := 0, 0
	for i := 0; i + 2 < len(model.mesh.indices); i += 3 {
		a := model.mesh.vertices[model.mesh.indices[i]]
		b := model.mesh.vertices[model.mesh.indices[i + 1]]
		c := model.mesh.vertices[model.mesh.indices[i + 2]]
		face := linalg.cross(b.position - a.position, c.position - a.position)
		if linalg.length(face) < 1e-9 do continue // degenerate
		total += 1
		if linalg.dot(face, a.normal + b.normal + c.normal) > 0 do agree += 1
	}
	testing.expect(t, total > 0)
	testing.expect(t, f32(agree) / f32(total) > 0.99)
}

@(test)
skinned_import_satisfies_joint_and_weight_invariants :: proc(t: ^testing.T) {
	model, ok := model_import_skinned_from_gltf("static/models/rigged_cesiumman.glb")
	testing.expect(t, ok)
	defer skinned_model_destroy(&model)
	if !ok do return

	joint_count := len(model.skin.joints)
	testing.expect(t, joint_count > 0 && joint_count <= MAX_JOINTS)
	testing.expect_value(t, len(model.skin.inverse_bind), joint_count)
	for joint, i in model.skin.joints do testing.expect(t, joint.parent < i32(i))
	for vertex in model.vertices {
		for joint in vertex.joints do testing.expect(t, int(joint) < joint_count)
		sum := vertex.weights[0] + vertex.weights[1] + vertex.weights[2] + vertex.weights[3]
		testing.expect(t, abs(sum - 1) < 1e-3)
	}
}

// CesiumMan's only root joint is under Armature (Rz -90°) under Z_UP (Rx -90°),
// both non-joint nodes: their product must reach the joint's palette.
@(test)
skinned_import_keeps_non_joint_root_ancestors :: proc(t: ^testing.T) {
	model, ok := model_import_skinned_from_gltf("static/models/rigged_cesiumman.glb")
	testing.expect(t, ok)
	defer skinned_model_destroy(&model)
	if !ok do return

	expected := linalg.matrix4_rotate_f32(-math.PI / 2, {1, 0, 0}) * linalg.matrix4_rotate_f32(-math.PI / 2, {0, 0, 1})
	testing.expect(t, model.skin.joints[0].parent == -1)
	for c in 0 ..< 4 do testing.expect(t, linalg.length(model.skin.joints[0].pre[c] - expected[c]) < 1e-4)
}

@(test)
gltf_has_skin_detects_rigged_models :: proc(t: ^testing.T) {
	testing.expect(t, gltf_has_skin("static/models/rigged_cesiumman.glb"))
	testing.expect(t, !gltf_has_skin("static/models/ship-large.glb"))
}
