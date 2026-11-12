package sdl

import input "../.."
import sdl3 "vendor:sdl3"

create :: proc() -> input.Adapter {
	return {event_type = typeid_of(sdl3.Event), register_event = register_event}
}

register_event :: proc(user_data: rawptr, system: ^input.System, raw_event: rawptr) -> bool {
	_ = user_data
	event := cast(^sdl3.Event)raw_event

	#partial switch event.type {
	case .KEY_DOWN, .KEY_UP:
		key, ok := key_from_scancode(event.key.scancode)
		if !ok do return false
		input.key_set(system, key, event.key.down)
		return true
	case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
		button, ok := mouse_button_from_sdl(event.button.button)
		if !ok do return false
		input.mouse_set_button(system, button, event.button.down)
		input.mouse_move(system, {event.button.x, event.button.y}, {})
		return true
	case .MOUSE_MOTION:
		input.mouse_move(
			system,
			{event.motion.x, event.motion.y},
			{event.motion.xrel, event.motion.yrel},
		)
		return true
	case .MOUSE_WHEEL:
		wheel := [2]f32{event.wheel.x, event.wheel.y}
		if event.wheel.direction == .FLIPPED do wheel = -wheel
		input.mouse_scroll(system, wheel)
		input.mouse_move(system, {event.wheel.mouse_x, event.wheel.mouse_y}, {})
		return true
	case .WINDOW_FOCUS_LOST:
		input.keyboard_reset(system)
		input.mouse_reset(system)
		return true
	}
	return false
}

key_from_scancode :: proc(scancode: sdl3.Scancode) -> (input.Key, bool) {
	key := input.Key(scancode)
	return key, input.key_is_valid(key)
}

mouse_button_from_sdl :: proc(button: u8) -> (input.Mouse_Button, bool) {
	if button < sdl3.BUTTON_LEFT || button > sdl3.BUTTON_X2 do return .Unknown, false
	mouse_button := input.Mouse_Button(button)
	return mouse_button, input.mouse_button_is_valid(mouse_button)
}
