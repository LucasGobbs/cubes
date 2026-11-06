package main

import "core:fmt"
import "core:math/linalg"
import gbbfx "gbbfx"
import glove "glove"

FlyCamera :: struct {
	move_action:  glove.Axis_2D_Action,
	boost_action: glove.Button_Action,
	up_action:    glove.Button_Action,
	down_action:  glove.Button_Action,
}

fly_camera_create :: proc(gfx: ^gbbfx.Gfx, prefix: string) -> FlyCamera {
	inputs := gbbfx.gfx_input(gfx)
	fly_camera := FlyCamera {
		move_action  = glove.add_axis_2d(inputs, fmt.tprintf("{}.move", prefix)),
		boost_action = glove.add_button(inputs, fmt.tprintf("{}.boost", prefix)),
		up_action    = glove.add_button(inputs, fmt.tprintf("{}.up", prefix)),
		down_action  = glove.add_button(inputs, fmt.tprintf("{}.down", prefix)),
	}

	glove.bind_button_axis_2d(
		inputs,
		fly_camera.move_action,
		{up = .W, down = .S, left = .A, right = .D, normalize = true},
	)
	glove.bind_key(inputs, fly_camera.boost_action, .LSHIFT)
	glove.bind_key(inputs, fly_camera.up_action, .SPACE)
	glove.bind_key(inputs, fly_camera.down_action, .LCTRL)


	return fly_camera
}

// look = false skips mouse rotation (editor: only rotate over the viewport).
fly_camera_tick :: proc(
	fly_camera: ^FlyCamera,
	gfx: ^gbbfx.Gfx,
	delta_time: f32,
	look := true,
) {
	inputs := gbbfx.gfx_input(gfx)

	camera := gbbfx.gfx_camera(gfx)
	if look {
		delta := glove.mouse_delta(inputs)
		gbbfx.camera_rotate(camera, delta.x * 0.1 * linalg.PI / 180, -delta.y * 0.1 * linalg.PI / 180)
	}
	move := glove.axis_2d(inputs, fly_camera.move_action)
	vertical: f32
	if glove.down(inputs, fly_camera.up_action) do vertical += 1
	if glove.down(inputs, fly_camera.down_action) do vertical -= 1
	boost: f32 = 1
	if glove.down(inputs, fly_camera.boost_action) do boost = 4
	direction := camera.direction * move.y + camera.right * move.x + gbbfx.Vec3{0, vertical, 0}
	if direction != {} do camera.position += direction * f32(5) * boost * delta_time
}
