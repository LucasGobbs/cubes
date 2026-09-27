package input

import sdl "vendor:sdl3"

sdl_adapter :: proc() -> Adapter {
	return {event_type = typeid_of(sdl.Event), register_event = sdl_register_event}
}

sdl_register_event :: proc(user_data: rawptr, system: ^System, raw_event: rawptr) -> bool {
	_ = user_data
	event := cast(^sdl.Event)raw_event

	#partial switch event.type {
	case .KEY_DOWN, .KEY_UP:
		key, ok := key_from_sdl_scancode(event.key.scancode)
		if !ok do return false
		key_set(system, key, event.key.down)
		return true

	case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
		button, ok := mouse_button_from_sdl(event.button.button)
		if !ok do return false
		mouse_set_button(system, button, event.button.down)
		mouse_move(system, {event.button.x, event.button.y}, {})
		return true

	case .MOUSE_MOTION:
		mouse_move(
			system,
			{event.motion.x, event.motion.y},
			{event.motion.xrel, event.motion.yrel},
		)
		return true

	case .MOUSE_WHEEL:
		wheel := [2]f32{event.wheel.x, event.wheel.y}
		if event.wheel.direction == .FLIPPED do wheel = -wheel
		mouse_scroll(system, wheel)
		mouse_move(system, {event.wheel.mouse_x, event.wheel.mouse_y}, {})
		return true

	case .WINDOW_FOCUS_LOST:
		keyboard_reset(system)
		mouse_reset(system)
		return true
	}

	return false
}

key_from_sdl_scancode :: proc(scancode: sdl.Scancode) -> (Key, bool) {
	key := Key(scancode)
	return key, key_is_valid(key)
}

mouse_button_from_sdl :: proc(button: u8) -> (Mouse_Button, bool) {
	if button < sdl.BUTTON_LEFT || button > sdl.BUTTON_X2 do return .Unknown, false
	mouse_button := Mouse_Button(button)
	return mouse_button, mouse_button_is_valid(mouse_button)
}
