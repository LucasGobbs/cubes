package gfx

import "core:math"
import "core:math/linalg"
import "core:testing"

@(test)
fly_camera_forward_moves_along_view_direction :: proc(t: ^testing.T) {
	camera := camera_create(position = {0, 0, 0}, target = {0, 0, -1})
	fly := fly_camera_create()
	before := camera.position
	forward := camera.direction

	fly_camera_update(&camera, &fly, Fly_Input{move = {0, 0, 1}}, 1)

	// speed 5 at dt 1 with smooth off: one step of 5 units along the view direction.
	moved := camera.position - before
	testing.expect(t, linalg.length(moved - forward * 5) < 1e-4)
}

@(test)
fly_camera_slow_scales_speed_and_stacks_with_boost :: proc(t: ^testing.T) {
	camera := camera_create(position = {0, 0, 0}, target = {0, 0, -1})
	fly := fly_camera_create()
	forward := camera.direction

	fly_camera_update(&camera, &fly, Fly_Input{move = {0, 0, 1}, slow = true}, 1)
	testing.expect(t, linalg.length(camera.position - forward * 5 * fly.slow) < 1e-4)

	camera.position = {}
	fly_camera_update(&camera, &fly, Fly_Input{move = {0, 0, 1}, slow = true, boost = true}, 1)
	testing.expect(t, linalg.length(camera.position - forward * 5 * fly.boost * fly.slow) < 1e-4)
}

@(test)
orbit_camera_distance_clamps :: proc(t: ^testing.T) {
	camera := camera_create()
	orbit := Orbit_Camera{target = {}, distance = 5, min_distance = 2, max_distance = 10}

	orbit_camera_update(&camera, &orbit, {}, -10, 1) // zoom out far past max
	testing.expect_value(t, orbit.distance, f32(10))
	testing.expect(t, math.abs(linalg.length(camera.position - orbit.target) - 10) < 1e-3)

	orbit_camera_update(&camera, &orbit, {}, 10, 1) // zoom in past min
	testing.expect_value(t, orbit.distance, f32(2))
}

@(test)
orthographic_maps_depth_reversed_into_zero_one :: proc(t: ^testing.T) {
	projection := lens_matrix(Orthographic{size = 1, near = 1, far = 11}, 1)
	ndc_depth :: proc(projection: matrix[4, 4]f32, distance: f32) -> f32 {
		clip := projection * [4]f32{0, 0, -distance, 1}
		return clip.z / clip.w
	}
	testing.expect(t, math.abs(ndc_depth(projection, 1) - 1) < 1e-5)
	testing.expect(t, math.abs(ndc_depth(projection, 11)) < 1e-5)
}
