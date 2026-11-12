package mock

import input "../.."

Event_Kind :: enum {
	Key,
	Keyboard_Reset,
	Mouse_Button,
	Mouse_Move,
	Mouse_Scroll,
	Mouse_Reset,
}

Event :: struct {
	kind:     Event_Kind,
	key:      input.Key,
	button:   input.Mouse_Button,
	down:     bool,
	position: [2]f32,
	delta:    [2]f32,
	wheel:    [2]f32,
}

create :: proc() -> input.Adapter {
	return {event_type = typeid_of(Event), register_event = register_event}
}

key_event :: proc(key: input.Key, down: bool) -> Event {
	return {kind = .Key, key = key, down = down}
}

keyboard_reset_event :: proc() -> Event {
	return {kind = .Keyboard_Reset}
}

mouse_button_event :: proc(button: input.Mouse_Button, down: bool) -> Event {
	return {kind = .Mouse_Button, button = button, down = down}
}

mouse_move_event :: proc(position, delta: [2]f32) -> Event {
	return {kind = .Mouse_Move, position = position, delta = delta}
}

mouse_scroll_event :: proc(wheel: [2]f32) -> Event {
	return {kind = .Mouse_Scroll, wheel = wheel}
}

mouse_reset_event :: proc() -> Event {
	return {kind = .Mouse_Reset}
}

register_event :: proc(user_data: rawptr, system: ^input.System, raw_event: rawptr) -> bool {
	_ = user_data
	event := cast(^Event)raw_event
	switch event.kind {
	case .Key:
		input.key_set(system, event.key, event.down)
	case .Keyboard_Reset:
		input.keyboard_reset(system)
	case .Mouse_Button:
		input.mouse_set_button(system, event.button, event.down)
	case .Mouse_Move:
		input.mouse_move(system, event.position, event.delta)
	case .Mouse_Scroll:
		input.mouse_scroll(system, event.wheel)
	case .Mouse_Reset:
		input.mouse_reset(system)
	}
	return true
}
