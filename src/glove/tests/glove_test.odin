package glove_tests

import glove ".."
import mock "../adapters/mock"
import glove_sdl "../adapters/sdl"
import "core:testing"
import sdl "vendor:sdl3"

@(test)
glove_wasd_resolves_axis_2d :: proc(t: ^testing.T) {
	inputs := glove.system_create(mock.create())
	defer glove.system_destroy(&inputs)
	move := glove.add_axis_2d(&inputs, "player.move")
	glove.bind_button_axis_2d(
		&inputs,
		move,
		{up = .W, down = .S, left = .A, right = .D, normalize = true},
	)

	event := mock.key_event(.W, true)
	testing.expect(t, glove.register_event(&inputs, &event))
	glove.update(&inputs)
	testing.expect_value(t, glove.axis_2d(&inputs, move), [2]f32{0, 1})
	event = mock.key_event(.D, true)
	glove.register_event(&inputs, &event)
	glove.update(&inputs)
	INV_SQRT_TWO :: f32(0.7071067811865475)
	testing.expect_value(t, glove.axis_2d(&inputs, move), [2]f32{INV_SQRT_TWO, INV_SQRT_TWO})

	events := [2]mock.Event{mock.key_event(.W, false), mock.key_event(.A, true)}
	testing.expect_value(t, glove.register_events(&inputs, events[:]), 2)
	glove.update(&inputs)
	testing.expect_value(t, glove.axis_2d(&inputs, move), [2]f32{})
}

@(test)
glove_button_reports_update_edges :: proc(t: ^testing.T) {
	inputs := glove.system_create(mock.create())
	defer glove.system_destroy(&inputs)
	quit := glove.add_button(&inputs, "app.quit")
	glove.bind_key(&inputs, quit, .ESCAPE)

	event := mock.key_event(.ESCAPE, true)
	glove.register_event(&inputs, &event)
	glove.update(&inputs)
	testing.expect(t, glove.down(&inputs, quit))
	testing.expect(t, glove.pressed(&inputs, quit))
	glove.update(&inputs)
	testing.expect(t, !glove.pressed(&inputs, quit))
	event = mock.key_event(.ESCAPE, false)
	glove.register_event(&inputs, &event)
	glove.update(&inputs)
	testing.expect(t, glove.released(&inputs, quit))
}

@(test)
glove_sdl_translates_keyboard_and_focus_loss :: proc(t: ^testing.T) {
	inputs := glove.system_create(glove_sdl.create())
	defer glove.system_destroy(&inputs)
	move := glove.add_axis_2d(&inputs, "player.move")
	glove.bind_button_axis_2d(
		&inputs,
		move,
		{up = .W, down = .S, left = .A, right = .D, normalize = true},
	)

	event: sdl.Event
	event.type = .KEY_DOWN
	event.key.scancode = .W
	event.key.down = true
	testing.expect(t, glove.register_event(&inputs, &event))
	glove.update(&inputs)
	testing.expect_value(t, glove.axis_2d(&inputs, move), [2]f32{0, 1})
	event = {}
	event.type = .WINDOW_FOCUS_LOST
	testing.expect(t, glove.register_event(&inputs, &event))
	glove.update(&inputs)
	testing.expect_value(t, glove.axis_2d(&inputs, move), [2]f32{})
}

@(test)
glove_sdl_translates_mouse :: proc(t: ^testing.T) {
	inputs := glove.system_create(glove_sdl.create())
	defer glove.system_destroy(&inputs)
	click := glove.add_button(&inputs, "ui.click")
	glove.bind_mouse_button(&inputs, click, .X2)

	events: [3]sdl.Event
	events[0].type = .MOUSE_BUTTON_DOWN
	events[0].button.button = sdl.BUTTON_X2
	events[0].button.down = true
	events[1].type = .MOUSE_MOTION
	events[1].motion.x = 15
	events[1].motion.y = 30
	events[1].motion.xrel = 5
	events[1].motion.yrel = 10
	events[2].type = .MOUSE_WHEEL
	events[2].wheel.x = 1
	events[2].wheel.y = -2
	events[2].wheel.direction = .FLIPPED
	glove.register_events(&inputs, events[:])
	glove.update(&inputs)
	testing.expect(t, glove.pressed(&inputs, click))
	testing.expect_value(t, glove.mouse_delta(&inputs), [2]f32{5, 10})
	testing.expect_value(t, glove.mouse_wheel(&inputs), [2]f32{-1, 2})
}

@(test)
glove_mock_drives_mouse :: proc(t: ^testing.T) {
	inputs := glove.system_create(mock.create())
	defer glove.system_destroy(&inputs)
	click := glove.add_button(&inputs, "ui.click")
	glove.bind_mouse_button(&inputs, click, .Left)
	events := [3]mock.Event {
		mock.mouse_button_event(.Left, true),
		mock.mouse_move_event({40, 50}, {3, -2}),
		mock.mouse_scroll_event({0, 1}),
	}
	glove.register_events(&inputs, events[:])
	glove.update(&inputs)
	testing.expect(t, glove.pressed(&inputs, click))
	testing.expect_value(t, glove.mouse_position(&inputs), [2]f32{40, 50})
	testing.expect_value(t, glove.mouse_delta(&inputs), [2]f32{3, -2})
}
