package scenekit

import "core:fmt"
import "core:math"
import "core:math/linalg"
import gbbfx "../gbbfx"
import glove "../glove"

BOOST_FACTOR :: 12 // shift multiplier on the base 5 units/s
SMOOTH_RATE :: 3.0 // 1/s; higher = snappier ease

FlyCamera :: struct {
	move_action:   glove.Axis_2D_Action,
	boost_action:  glove.Button_Action,
	up_action:     glove.Button_Action,
	down_action:   glove.Button_Action,
	smooth_action: glove.Button_Action,
	smooth:        bool,
	velocity:      gbbfx.Vec3,
	look_velocity: [2]f32,
}

fly_camera_create :: proc(gfx: ^gbbfx.Gfx, prefix: string) -> FlyCamera {
	inputs := gbbfx.gfx_input(gfx)
	fly_camera := FlyCamera {
		move_action  = glove.add_axis_2d(inputs, fmt.tprintf("{}.move", prefix)),
		boost_action = glove.add_button(inputs, fmt.tprintf("{}.boost", prefix)),
		up_action    = glove.add_button(inputs, fmt.tprintf("{}.up", prefix)),
		down_action  = glove.add_button(inputs, fmt.tprintf("{}.down", prefix)),
		smooth_action = glove.add_button(inputs, fmt.tprintf("{}.smooth", prefix)),
	}

	glove.bind_button_axis_2d(
		inputs,
		fly_camera.move_action,
		{up = .W, down = .S, left = .A, right = .D, normalize = true},
	)
	glove.bind_key(inputs, fly_camera.boost_action, .LSHIFT)
	glove.bind_key(inputs, fly_camera.up_action, .SPACE)
	glove.bind_key(inputs, fly_camera.down_action, .LCTRL)
	glove.bind_key(inputs, fly_camera.smooth_action, .C)


	return fly_camera
}

// look = false skips mouse rotation (editor: only rotate over the viewport).
// C toggles smooth mode: movement and look ease in and out, for recording walkthroughs.
fly_camera_tick :: proc(
	fly_camera: ^FlyCamera,
	gfx: ^gbbfx.Gfx,
	delta_time: f32,
	look := true,
) {
	inputs := gbbfx.gfx_input(gfx)
	if glove.pressed(inputs, fly_camera.smooth_action) do fly_camera.smooth = !fly_camera.smooth

	// Exponential ease toward the target; 1 when not smooth (instant response).
	ease: f32 = 1
	if fly_camera.smooth do ease = 1 - math.exp(-SMOOTH_RATE * delta_time)

	camera := gbbfx.gfx_camera(gfx)
	look_target: [2]f32
	if look do look_target = glove.mouse_delta(inputs)
	fly_camera.look_velocity += (look_target - fly_camera.look_velocity) * ease
	look_delta := fly_camera.look_velocity
	gbbfx.camera_rotate(camera, look_delta.x * 0.1 * linalg.PI / 180, -look_delta.y * 0.1 * linalg.PI / 180)

	move := glove.axis_2d(inputs, fly_camera.move_action)
	vertical: f32
	if glove.down(inputs, fly_camera.up_action) do vertical += 1
	if glove.down(inputs, fly_camera.down_action) do vertical -= 1
	boost: f32 = 1
	if glove.down(inputs, fly_camera.boost_action) do boost = BOOST_FACTOR
	direction := camera.direction * move.y + camera.right * move.x + gbbfx.Vec3{0, vertical, 0}
	fly_camera.velocity += (direction * f32(5) * boost - fly_camera.velocity) * ease
	camera.position += fly_camera.velocity * delta_time
}
