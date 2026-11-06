package gbbfx

import "core:math"
import "core:math/linalg"
import "core:testing"

// Camera at the origin looking down -z, 90-degree-ish perspective, square aspect.
test_planes :: proc() -> [4][4]f32 {
	camera := camera_create(position = {0, 0, 0}, target = {0, 0, -1}, projection = camera_perspective(1))
	return frustum_planes(camera_view_projection(&camera))
}

@(test)
culling_rejects_spheres_outside_side_planes :: proc(t: ^testing.T) {
	planes := test_planes()
	unit := Mesh{radius = 1}
	at :: proc(p: Vec3) -> matrix[4, 4]f32 {return linalg.matrix4_translate_f32(p)}

	testing.expect(t, !renderable_culled(&planes, &unit, at({0, 0, -10})), "ahead on axis")
	testing.expect(t, renderable_culled(&planes, &unit, at({-100, 0, -10})), "far left")
	testing.expect(t, renderable_culled(&planes, &unit, at({100, 0, -10})), "far right")
	testing.expect(t, renderable_culled(&planes, &unit, at({0, 100, -10})), "far above")
	testing.expect(t, renderable_culled(&planes, &unit, at({0, -100, -10})), "far below")
	testing.expect(t, renderable_culled(&planes, &unit, at({0, 0, 10})), "behind the camera")
}

@(test)
culling_keeps_spheres_touching_the_frustum :: proc(t: ^testing.T) {
	planes := test_planes()
	// A sphere centered outside the left plane but big enough to overlap the frustum stays.
	big := Mesh{radius = 50}
	testing.expect(t, !renderable_culled(&planes, &big, linalg.matrix4_translate_f32({-30, 0, -10})))
}

@(test)
culling_uses_world_scale_and_mesh_center :: proc(t: ^testing.T) {
	planes := test_planes()
	outside := linalg.matrix4_translate_f32({-40, 0, -10})
	small := Mesh{radius = 1}
	testing.expect(t, renderable_culled(&planes, &small, outside))
	// Same mesh scaled x100 reaches back into view.
	scaled := outside * linalg.matrix4_scale_f32({100, 100, 100})
	testing.expect(t, !renderable_culled(&planes, &small, scaled))
	// Local center offset moves the sphere: mesh centered at +x pulls it into view.
	offset := Mesh{center = {40, 0, 0}, radius = 1}
	testing.expect(t, !renderable_culled(&planes, &offset, outside))
}

@(test)
culling_never_rejects_unbounded_mesh :: proc(t: ^testing.T) {
	planes := test_planes()
	unknown := Mesh{} // radius 0 = bounds unknown
	testing.expect(t, !renderable_culled(&planes, &unknown, linalg.matrix4_translate_f32({1000, 0, 500})))
}

@(test)
mesh_bounds_enclose_all_vertices :: proc(t: ^testing.T) {
	vertices := [3]VertexData{{position = {-1, 0, 0}}, {position = {3, 0, 0}}, {position = {1, 2, 0}}}
	mesh: Mesh
	mesh_set_bounds(&mesh, vertices[:])
	testing.expect_value(t, mesh.center, Vec3{1, 1, 0})
	for vertex in vertices {
		testing.expect(t, linalg.length(vertex.position - mesh.center) <= mesh.radius + 0.0001)
	}
	testing.expect(t, math.abs(mesh.radius - math.sqrt(f32(5))) < 0.0001)
}
