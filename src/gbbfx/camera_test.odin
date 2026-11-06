package gbbfx

import "core:math"
import "core:math/linalg"
import "core:testing"

@(test)
camera_rotation_updates_yaw_pitch_and_basis :: proc(t: ^testing.T) {
	camera := camera_create(position = {0, 0, 3}, target = {})

	camera_rotate(&camera, linalg.to_radians(f32(90)), 0)
	testing.expect(t, math.abs(camera.direction.x - 1) < 0.0001)
	testing.expect(t, math.abs(camera.direction.y) < 0.0001)
	testing.expect(t, math.abs(camera.direction.z) < 0.0001)
	testing.expect(t, math.abs(camera.right.z - 1) < 0.0001)

	camera_rotate(&camera, 0, linalg.to_radians(f32(180)))
	pitch_limit := linalg.to_radians(f32(89))
	testing.expect_value(t, camera.pitch, pitch_limit)
	testing.expect(t, camera.direction.y > 0.999)
}

@(test)
camera_perspective_maps_depth_reversed_into_zero_one :: proc(t: ^testing.T) {
	projection := camera_perspective(16.0 / 9.0)
	ndc_depth :: proc(projection: matrix[4, 4]f32, distance: f32) -> f32 {
		clip := projection * [4]f32{0, 0, -distance, 1} // view space looks down -z
		return clip.z / clip.w
	}
	testing.expect(t, math.abs(ndc_depth(projection, CAMERA_NEAR) - 1) < 0.0001)
	far_depth := ndc_depth(projection, 100000)
	testing.expect(t, far_depth > 0 && far_depth < 0.0001)
	testing.expect(t, ndc_depth(projection, 1) > ndc_depth(projection, 10))
}
