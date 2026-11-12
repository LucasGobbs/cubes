package gfx

import "core:math"

// Camera circles target at distance; yaw/pitch as in Camera.
Orbit_Camera :: struct {
	target:                     Vec3,
	distance:                   f32,
	min_distance, max_distance: f32,
	yaw, pitch:                 f32,
}

// delta: yaw/pitch rate in rad/s. zoom: log-distance rate per second (positive = closer).
// Both are scaled by dt; distance is clamped to [min_distance, max_distance].
orbit_camera_update :: proc(camera: ^Camera, orbit: ^Orbit_Camera, delta: [2]f32, zoom: f32, dt: f32) {
	orbit.yaw += delta.x * dt
	limit := camera_pitch_limit()
	orbit.pitch = math.clamp(orbit.pitch + delta.y * dt, -limit, limit)
	orbit.distance = math.clamp(
		orbit.distance * math.exp(-zoom * dt),
		orbit.min_distance,
		orbit.max_distance,
	)

	camera_set_angles(camera, orbit.yaw, orbit.pitch)
	camera.position = orbit.target - camera.direction * orbit.distance
}
