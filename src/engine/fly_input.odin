package engine

import "core:fmt"
import gfx "gfx"
import input "input"

// Key bindings for gfx.Fly_Camera: WASD move, Space/LCtrl up/down, LShift boost, LAlt slow, C smooth.
Fly_Controls :: struct {
	move:   input.Axis_2D_Action,
	boost:  input.Button_Action,
	slow:   input.Button_Action,
	up:     input.Button_Action,
	down:   input.Button_Action,
	smooth: input.Button_Action,
}

fly_controls_create :: proc(inp: ^input.System, prefix: string) -> Fly_Controls {
	controls := Fly_Controls {
		move   = input.add_axis_2d(inp, fmt.tprintf("{}.move", prefix), "Fly move"),
		boost  = input.button(inp, fmt.tprintf("{}.boost", prefix), .LSHIFT, "Fly boost"),
		slow   = input.button(inp, fmt.tprintf("{}.slow", prefix), .LALT, "Fly slow"),
		up     = input.button(inp, fmt.tprintf("{}.up", prefix), .SPACE, "Fly up"),
		down   = input.button(inp, fmt.tprintf("{}.down", prefix), .LCTRL, "Fly down"),
		smooth = input.button(inp, fmt.tprintf("{}.smooth", prefix), .C, "Toggle smooth camera"),
	}
	input.bind_button_axis_2d(inp, controls.move, {up = .W, down = .S, left = .A, right = .D, normalize = true})
	return controls
}

// look = false skips mouse rotation (editor: only rotate over the viewport).
fly_controls_read :: proc(inp: ^input.System, controls: ^Fly_Controls, look := true) -> gfx.Fly_Input {
	move := input.axis_2d(inp, controls.move)
	vertical: f32
	if input.down(inp, controls.up) do vertical += 1
	if input.down(inp, controls.down) do vertical -= 1

	result := gfx.Fly_Input {
		move          = {move.x, vertical, move.y},
		boost         = input.down(inp, controls.boost),
		slow          = input.down(inp, controls.slow),
		toggle_smooth = input.pressed(inp, controls.smooth),
	}
	if look do result.look = input.mouse_delta(inp)
	return result
}
