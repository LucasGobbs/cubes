package default

import "core:fmt"
import "core:math"
import "core:math/linalg"
import gfx "../gfx"
import input "../input"

BOOST_FACTOR :: 12 // shift multiplier on the base 5 units/s
SMOOTH_RATE :: 3.0 // 1/s; higher = snappier ease

Fly_Camera :: struct {
	move_action:   input.Axis_2D_Action,
	boost_action:  input.Button_Action,
	up_action:     input.Button_Action,
	down_action:   input.Button_Action,
	smooth_action: input.Button_Action,
	smooth:        bool,
	velocity:      gfx.Vec3,
	look_velocity: [2]f32,
}

fly_camera_create :: proc(dev: ^gfx.Device, inp: ^input.System, prefix: string) -> Fly_Camera {
	fly_camera := Fly_Camera {
		move_action  = input.add_axis_2d(inp, fmt.tprintf("{}.move", prefix)),
		boost_action = input.button(inp, fmt.tprintf("{}.boost", prefix)),
		up_action    = input.button(inp, fmt.tprintf("{}.up", prefix)),
		down_action  = input.button(inp, fmt.tprintf("{}.down", prefix)),
		smooth_action = input.button(inp, fmt.tprintf("{}.smooth", prefix)),
	}

	input.bind_button_axis_2d(
		inp,
		fly_camera.move_action,
		{up = .W, down = .S, left = .A, right = .D, normalize = true},
	)
	input.bind_key(inp, fly_camera.boost_action, .LSHIFT)
	input.bind_key(inp, fly_camera.up_action, .SPACE)
	input.bind_key(inp, fly_camera.down_action, .LCTRL)
	input.bind_key(inp, fly_camera.smooth_action, .C)


	return fly_camera
}

// look = false skips mouse rotation (editor: only rotate over the viewport).
// C toggles smooth mode: movement and look ease in and out, for recording walkthroughs.
fly_camera_tick :: proc(
	fly_camera: ^Fly_Camera,
	dev: ^gfx.Device,
	inp: ^input.System,
	delta_time: f32,
	look := true,
) {
	if input.pressed(inp, fly_camera.smooth_action) do fly_camera.smooth = !fly_camera.smooth

	// Exponential ease toward the target; 1 when not smooth (instant response).
	ease: f32 = 1
	if fly_camera.smooth do ease = 1 - math.exp(-SMOOTH_RATE * delta_time)

	camera := gfx.camera(dev)
	look_target: [2]f32
	if look do look_target = input.mouse_delta(inp)
	fly_camera.look_velocity += (look_target - fly_camera.look_velocity) * ease
	look_delta := fly_camera.look_velocity
	gfx.camera_rotate(camera, look_delta.x * 0.1 * linalg.PI / 180, -look_delta.y * 0.1 * linalg.PI / 180)

	move := input.axis_2d(inp, fly_camera.move_action)
	vertical: f32
	if input.down(inp, fly_camera.up_action) do vertical += 1
	if input.down(inp, fly_camera.down_action) do vertical -= 1
	boost: f32 = 1
	if input.down(inp, fly_camera.boost_action) do boost = BOOST_FACTOR
	direction := camera.direction * move.y + camera.right * move.x + gfx.Vec3{0, vertical, 0}
	fly_camera.velocity += (direction * f32(5) * boost - fly_camera.velocity) * ease
	camera.position += fly_camera.velocity * delta_time
}
