package main

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
