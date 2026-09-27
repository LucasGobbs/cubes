package input

Mock_Event_Kind :: enum {
	Key,
	Keyboard_Reset,
	Mouse_Button,
	Mouse_Move,
	Mouse_Scroll,
	Mouse_Reset,
}

Mock_Event :: struct {
	kind:     Mock_Event_Kind,
	key:      Key,
	button:   Mouse_Button,
	down:     bool,
	position: [2]f32,
	delta:    [2]f32,
	wheel:    [2]f32,
}

mock_adapter :: proc() -> Adapter {
	return {event_type = typeid_of(Mock_Event), register_event = mock_register_event}
}

mock_key_event :: proc(key: Key, down: bool) -> Mock_Event {
	return {kind = .Key, key = key, down = down}
}

mock_keyboard_reset_event :: proc() -> Mock_Event {
	return {kind = .Keyboard_Reset}
}

mock_mouse_button_event :: proc(button: Mouse_Button, down: bool) -> Mock_Event {
	return {kind = .Mouse_Button, button = button, down = down}
}

mock_mouse_move_event :: proc(position, delta: [2]f32) -> Mock_Event {
	return {kind = .Mouse_Move, position = position, delta = delta}
}

mock_mouse_scroll_event :: proc(wheel: [2]f32) -> Mock_Event {
	return {kind = .Mouse_Scroll, wheel = wheel}
}

mock_mouse_reset_event :: proc() -> Mock_Event {
	return {kind = .Mouse_Reset}
}

mock_register_event :: proc(user_data: rawptr, system: ^System, raw_event: rawptr) -> bool {
	_ = user_data
	event := cast(^Mock_Event)raw_event

	switch event.kind {
	case .Key:
		key_set(system, event.key, event.down)
	case .Keyboard_Reset:
		keyboard_reset(system)
	case .Mouse_Button:
		mouse_set_button(system, event.button, event.down)
	case .Mouse_Move:
		mouse_move(system, event.position, event.delta)
	case .Mouse_Scroll:
		mouse_scroll(system, event.wheel)
	case .Mouse_Reset:
		mouse_reset(system)
	}

	return true
}
