package main

import "core:math"
import "core:os"
import "core:testing"

// Run from the repository root: SPHERE_PATH is relative to it.

@(test)
test_committed_sphere_matches_generator :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	committed, err := os.read_entire_file(SPHERE_PATH, context.allocator)
	testing.expect_value(t, err, nil)
	testing.expect(t, string(committed) == string(build_glb(build_sphere())), "run make models")
}

@(test)
test_sphere_is_unit_radius_with_outward_normals :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	mesh := build_sphere()
	for p, i in mesh.positions {
		testing.expect(t, abs(math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z) - 1) < 1e-5)
		testing.expect(t, mesh.normals[i] == p)
	}
	testing.expect_value(t, len(mesh.indices), 3 * (2 * SEGMENTS * RINGS - 2 * SEGMENTS))
	for index in mesh.indices do testing.expect(t, int(index) < len(mesh.positions))
}
