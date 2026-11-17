package input_tests

import input ".."
import mock "../adapters/mock"
import input_sdl "../adapters/sdl"
import "core:testing"
import sdl "vendor:sdl3"

@(test)
input_wasd_resolves_axis_2d :: proc(t: ^testing.T) {
	inputs := input.system_create(mock.create())
	defer input.system_destroy(&inputs)
	move := input.add_axis_2d(&inputs, "player.move")
	input.bind_button_axis_2d(
		&inputs,
		move,
		{up = .W, down = .S, left = .A, right = .D, normalize = true},
	)

	event := mock.key_event(.W, true)
	testing.expect(t, input.register_event(&inputs, &event))
	input.update(&inputs)
	testing.expect_value(t, input.axis_2d(&inputs, move), [2]f32{0, 1})
	event = mock.key_event(.D, true)
	input.register_event(&inputs, &event)
	input.update(&inputs)
	INV_SQRT_TWO :: f32(0.7071067811865475)
	testing.expect_value(t, input.axis_2d(&inputs, move), [2]f32{INV_SQRT_TWO, INV_SQRT_TWO})

	events := [2]mock.Event{mock.key_event(.W, false), mock.key_event(.A, true)}
	testing.expect_value(t, input.register_events(&inputs, events[:]), 2)
	input.update(&inputs)
	testing.expect_value(t, input.axis_2d(&inputs, move), [2]f32{})
}

@(test)
input_button_reports_update_edges :: proc(t: ^testing.T) {
	inputs := input.system_create(mock.create())
	defer input.system_destroy(&inputs)
	quit := input.button(&inputs, "app.quit")
	input.bind_key(&inputs, quit, .ESCAPE)

	event := mock.key_event(.ESCAPE, true)
	input.register_event(&inputs, &event)
	input.update(&inputs)
	testing.expect(t, input.down(&inputs, quit))
	testing.expect(t, input.pressed(&inputs, quit))
	input.update(&inputs)
	testing.expect(t, !input.pressed(&inputs, quit))
	event = mock.key_event(.ESCAPE, false)
	input.register_event(&inputs, &event)
	input.update(&inputs)
	testing.expect(t, input.released(&inputs, quit))
}

@(test)
input_sdl_translates_keyboard_and_focus_loss :: proc(t: ^testing.T) {
	inputs := input.system_create(input_sdl.create())
	defer input.system_destroy(&inputs)
	move := input.add_axis_2d(&inputs, "player.move")
	input.bind_button_axis_2d(
		&inputs,
		move,
		{up = .W, down = .S, left = .A, right = .D, normalize = true},
	)

	event: sdl.Event
	event.type = .KEY_DOWN
	event.key.scancode = .W
	event.key.down = true
	testing.expect(t, input.register_event(&inputs, &event))
	input.update(&inputs)
	testing.expect_value(t, input.axis_2d(&inputs, move), [2]f32{0, 1})
	event = {}
	event.type = .WINDOW_FOCUS_LOST
	testing.expect(t, input.register_event(&inputs, &event))
	input.update(&inputs)
	testing.expect_value(t, input.axis_2d(&inputs, move), [2]f32{})
}

@(test)
input_sdl_translates_mouse :: proc(t: ^testing.T) {
	inputs := input.system_create(input_sdl.create())
	defer input.system_destroy(&inputs)
	click := input.button(&inputs, "ui.click")
	input.bind_mouse_button(&inputs, click, .X2)

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
	input.register_events(&inputs, events[:])
	input.update(&inputs)
	testing.expect(t, input.pressed(&inputs, click))
	testing.expect_value(t, input.mouse_delta(&inputs), [2]f32{5, 10})
	testing.expect_value(t, input.mouse_wheel(&inputs), [2]f32{-1, 2})
}

@(test)
input_mock_drives_mouse :: proc(t: ^testing.T) {
	inputs := input.system_create(mock.create())
	defer input.system_destroy(&inputs)
	click := input.button(&inputs, "ui.click")
	input.bind_mouse_button(&inputs, click, .Left)
	events := [3]mock.Event {
		mock.mouse_button_event(.Left, true),
		mock.mouse_move_event({40, 50}, {3, -2}),
		mock.mouse_scroll_event({0, 1}),
	}
	input.register_events(&inputs, events[:])
	input.update(&inputs)
	testing.expect(t, input.pressed(&inputs, click))
	testing.expect_value(t, input.mouse_position(&inputs), [2]f32{40, 50})
	testing.expect_value(t, input.mouse_delta(&inputs), [2]f32{3, -2})
}

@(test)
input_rewind_drops_actions_and_bindings_added_after_mark :: proc(t: ^testing.T) {
	inputs := input.system_create(mock.create())
	defer input.system_destroy(&inputs)
	quit := input.button(&inputs, "app.quit")
	input.bind_key(&inputs, quit, .ESCAPE)

	mark := input.system_mark(&inputs)
	jump := input.button(&inputs, "scene.jump")
	move := input.add_axis_2d(&inputs, "scene.move")
	input.bind_key(&inputs, jump, .SPACE)
	input.bind_button_axis_2d(&inputs, move, {up = .W, down = .S, left = .A, right = .D})
	input.system_rewind(&inputs, mark)

	testing.expect_value(t, len(inputs.button_actions), 1)
	testing.expect_value(t, len(inputs.axis_2d_actions), 0)
	testing.expect_value(t, len(inputs.key_bindings), 1)
	testing.expect_value(t, len(inputs.button_axis_2d_bindings), 0)

	event := mock.key_event(.ESCAPE, true)
	input.register_event(&inputs, &event)
	input.update(&inputs)
	testing.expect(t, input.pressed(&inputs, quit))
}

@(test)
input_button_key_argument_binds_and_reports_pressed :: proc(t: ^testing.T) {
	inputs := input.system_create(mock.create())
	defer input.system_destroy(&inputs)
	jump := input.button(&inputs, "player.jump", .SPACE)
	testing.expect_value(t, len(inputs.key_bindings), 1)

	event := mock.key_event(.SPACE, true)
	input.register_event(&inputs, &event)
	input.update(&inputs)
	testing.expect(t, input.pressed(&inputs, jump))
}

@(test)
input_move_2d_named_keys_resolve_axis :: proc(t: ^testing.T) {
	inputs := input.system_create(mock.create())
	defer input.system_destroy(&inputs)
	move := input.move_2d(&inputs, "player.move", up = .W, down = .S, left = .A, right = .D)

	event := mock.key_event(.D, true)
	input.register_event(&inputs, &event)
	input.update(&inputs)
	testing.expect_value(t, input.axis_2d(&inputs, move), [2]f32{1, 0})

	// opposite pair held together cancels to zero
	event = mock.key_event(.A, true)
	input.register_event(&inputs, &event)
	input.update(&inputs)
	testing.expect_value(t, input.axis_2d(&inputs, move), [2]f32{0, 0})

	// diagonal is not normalized: right + up = {1, 1}
	event = mock.key_event(.A, false)
	input.register_event(&inputs, &event)
	event = mock.key_event(.D, false)
	input.register_event(&inputs, &event)
	event = mock.key_event(.W, true)
	input.register_event(&inputs, &event)
	event = mock.key_event(.D, true)
	input.register_event(&inputs, &event)
	input.update(&inputs)
	testing.expect_value(t, input.axis_2d(&inputs, move), [2]f32{1, 1})
}

@(test)
input_actions_list_descriptions_keys_and_rewind :: proc(t: ^testing.T) {
	inputs := input.system_create(mock.create())
	defer input.system_destroy(&inputs)
	input.button(&inputs, "player.jump", .SPACE, "Jump")
	input.move_2d(&inputs, "player.move", up = .W, down = .S, left = .A, right = .D, description = "Move")
	click := input.button(&inputs, "ui.click", description = "Click")
	input.bind_mouse_button(&inputs, click, .Left)
	input.button(&inputs, "ui.idle")
	mark := input.system_mark(&inputs)
	input.button(&inputs, "player.dash", .LSHIFT, "Dash")
	input.system_rewind(&inputs, mark)

	actions := input.system_actions(&inputs)
	testing.expect_value(t, len(actions), 4)
	if len(actions) != 4 do return
	testing.expect_value(t, actions[0], input.Action_Info{name = "player.jump", description = "Jump", keys = "SPACE"})
	testing.expect_value(t, actions[1], input.Action_Info{name = "player.move", description = "Move", keys = "W/S/A/D"})
	testing.expect_value(t, actions[2], input.Action_Info{name = "ui.click", description = "Click", keys = "MOUSE_Left"})
	testing.expect_value(t, actions[3], input.Action_Info{name = "ui.idle", description = "", keys = ""})
}
