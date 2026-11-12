package gfx

import "core:math"
import "core:math/linalg"

// Input-agnostic per-frame command; engine maps keys and mouse into it.
Fly_Input :: struct {
	move:          Vec3, // x right, y up, z forward; each axis in [-1, 1]
	look:          [2]f32, // mouse delta this frame; 0 disables look
	boost:         bool,
	toggle_smooth: bool, // edge: flips smooth mode
}

Fly_Camera :: struct {
	speed:         f32, // base units/s
	boost:         f32, // multiplier while Fly_Input.boost
	sensitivity:   f32, // degrees per look unit
	smooth_rate:   f32, // 1/s; higher = snappier ease in smooth mode
	smooth:        bool,
	velocity:      Vec3,
	look_velocity: [2]f32,
}

fly_camera_create :: proc() -> Fly_Camera {
	return Fly_Camera{speed = 5, boost = 12, sensitivity = 0.1, smooth_rate = 3}
}

// Smooth mode eases movement and look toward their targets, for recording walkthroughs.
fly_camera_update :: proc(camera: ^Camera, fly: ^Fly_Camera, input: Fly_Input, dt: f32) {
	if input.toggle_smooth do fly.smooth = !fly.smooth

	// Exponential ease toward the target; 1 when not smooth (instant response).
	ease: f32 = 1
	if fly.smooth do ease = 1 - math.exp(-fly.smooth_rate * dt)

	fly.look_velocity += (input.look - fly.look_velocity) * ease
	camera_rotate(
		camera,
		fly.look_velocity.x * fly.sensitivity * linalg.PI / 180,
		-fly.look_velocity.y * fly.sensitivity * linalg.PI / 180,
	)

	boost: f32 = 1
	if input.boost do boost = fly.boost
	direction := camera.direction * input.move.z + camera.right * input.move.x + Vec3{0, input.move.y, 0}
	fly.velocity += (direction * fly.speed * boost - fly.velocity) * ease
	camera.position += fly.velocity * dt
}
