package input

import "core:testing"
import sdl "vendor:sdl3"

@(test)
input_wasd_resolves_axis_2d :: proc(t: ^testing.T) {
	inputs := system_create(mock_adapter())
	defer system_destroy(&inputs)

	move := add_axis_2d(&inputs, "player.move")
	bind_button_axis_2d(
		&inputs,
		move,
		{up = .W, down = .S, left = .A, right = .D, normalize = true},
	)

	event := mock_key_event(.W, true)
	testing.expect(t, register_event(&inputs, &event))
	update(&inputs)
	testing.expect_value(t, axis_2d(&inputs, move), [2]f32{0, 1})
	testing.expect(t, axis_2d_changed(&inputs, move))

	event = mock_key_event(.D, true)
	register_event(&inputs, &event)
	update(&inputs)
	INV_SQRT_TWO :: f32(0.7071067811865475)
	testing.expect_value(t, axis_2d(&inputs, move), [2]f32{INV_SQRT_TWO, INV_SQRT_TWO})

	events := [2]Mock_Event{mock_key_event(.W, false), mock_key_event(.A, true)}
	testing.expect_value(t, register_events(&inputs, events[:]), 2)
	update(&inputs)
	testing.expect_value(t, axis_2d(&inputs, move), [2]f32{})
}

@(test)
input_button_reports_update_edges :: proc(t: ^testing.T) {
	inputs := system_create(mock_adapter())
	defer system_destroy(&inputs)

	quit := add_button(&inputs, "app.quit")
	bind_key(&inputs, quit, .ESCAPE)

	event := mock_key_event(.ESCAPE, true)
	register_event(&inputs, &event)
	update(&inputs)
	testing.expect(t, down(&inputs, quit))
	testing.expect(t, pressed(&inputs, quit))
	testing.expect(t, !released(&inputs, quit))

	update(&inputs)
	testing.expect(t, down(&inputs, quit))
	testing.expect(t, !pressed(&inputs, quit))

	event = mock_key_event(.ESCAPE, false)
	register_event(&inputs, &event)
	update(&inputs)
	testing.expect(t, !down(&inputs, quit))
	testing.expect(t, released(&inputs, quit))
}

@(test)
input_sdl_adapter_translates_keyboard_and_focus_loss :: proc(t: ^testing.T) {
	inputs := system_create(sdl_adapter())
	defer system_destroy(&inputs)

	move := add_axis_2d(&inputs, "player.move")
	bind_button_axis_2d(
		&inputs,
		move,
		{up = .W, down = .S, left = .A, right = .D, normalize = true},
	)

	event: sdl.Event
	event.type = .KEY_DOWN
	event.key.scancode = .W
	event.key.down = true
	testing.expect(t, register_event(&inputs, &event))
	update(&inputs)
	testing.expect_value(t, axis_2d(&inputs, move), [2]f32{0, 1})

	event = {}
	event.type = .WINDOW_FOCUS_LOST
	testing.expect(t, register_event(&inputs, &event))
	update(&inputs)
	testing.expect_value(t, axis_2d(&inputs, move), [2]f32{})
}

@(test)
input_sdl_adapter_translates_extended_keys :: proc(t: ^testing.T) {
	inputs := system_create(sdl_adapter())
	defer system_destroy(&inputs)

	hotkey := add_button(&inputs, "app.hotkey")
	bind_key(&inputs, hotkey, .F24)
	bind_key(&inputs, hotkey, .MEDIA_PLAY_PAUSE)

	input_event: sdl.Event
	input_event.type = .KEY_DOWN
	input_event.key.scancode = .F24
	input_event.key.down = true
	testing.expect(t, register_event(&inputs, &input_event))
	update(&inputs)
	testing.expect(t, pressed(&inputs, hotkey))

	input_event = {}
	input_event.type = .KEY_UP
	input_event.key.scancode = .F24
	input_event.key.down = false
	testing.expect(t, register_event(&inputs, &input_event))
	update(&inputs)
	testing.expect(t, released(&inputs, hotkey))

	input_event = {}
	input_event.type = .KEY_DOWN
	input_event.key.scancode = .MEDIA_PLAY_PAUSE
	input_event.key.down = true
	testing.expect(t, register_event(&inputs, &input_event))
	update(&inputs)
	testing.expect(t, pressed(&inputs, hotkey))

	input_event.key.scancode = sdl.Scancode(400)
	testing.expect(t, !register_event(&inputs, &input_event))
}

@(test)
input_sdl_adapter_translates_mouse :: proc(t: ^testing.T) {
	inputs := system_create(sdl_adapter())
	defer system_destroy(&inputs)

	click := add_button(&inputs, "ui.click")
	bind_mouse_button(&inputs, click, .X2)

	events: [3]sdl.Event
	events[0].type = .MOUSE_BUTTON_DOWN
	events[0].button.button = sdl.BUTTON_X2
	events[0].button.down = true
	events[0].button.x = 10
	events[0].button.y = 20
	events[1].type = .MOUSE_MOTION
	events[1].motion.x = 15
	events[1].motion.y = 30
	events[1].motion.xrel = 5
	events[1].motion.yrel = 10
	events[2].type = .MOUSE_WHEEL
	events[2].wheel.x = 1
	events[2].wheel.y = -2
	events[2].wheel.direction = .FLIPPED
	events[2].wheel.mouse_x = 15
	events[2].wheel.mouse_y = 30

	testing.expect_value(t, register_events(&inputs, events[:]), 3)
	update(&inputs)
	testing.expect(t, pressed(&inputs, click))
	testing.expect(t, mouse_down(&inputs, .X2))
	testing.expect_value(t, mouse_position(&inputs), [2]f32{15, 30})
	testing.expect_value(t, mouse_delta(&inputs), [2]f32{5, 10})
	testing.expect_value(t, mouse_wheel(&inputs), [2]f32{-1, 2})

	event: sdl.Event
	event.type = .WINDOW_FOCUS_LOST
	register_event(&inputs, &event)
	update(&inputs)
	testing.expect(t, released(&inputs, click))
	testing.expect_value(t, mouse_delta(&inputs), [2]f32{})
	testing.expect_value(t, mouse_wheel(&inputs), [2]f32{})
}

@(test)
input_mock_adapter_drives_mouse :: proc(t: ^testing.T) {
	inputs := system_create(mock_adapter())
	defer system_destroy(&inputs)

	click := add_button(&inputs, "ui.click")
	bind_mouse_button(&inputs, click, .Left)

	events := [3]Mock_Event {
		mock_mouse_button_event(.Left, true),
		mock_mouse_move_event({40, 50}, {3, -2}),
		mock_mouse_scroll_event({0, 1}),
	}
	register_events(&inputs, events[:])
	update(&inputs)
	testing.expect(t, pressed(&inputs, click))
	testing.expect_value(t, mouse_position(&inputs), [2]f32{40, 50})
	testing.expect_value(t, mouse_delta(&inputs), [2]f32{3, -2})
	testing.expect_value(t, mouse_wheel(&inputs), [2]f32{0, 1})

	event := mock_mouse_reset_event()
	register_event(&inputs, &event)
	update(&inputs)
	testing.expect(t, released(&inputs, click))
}
