package input

import "core:strings"

system_create :: proc(adapter: Adapter, allocator := context.allocator) -> System {
	assert(adapter.event_type != nil)
	assert(adapter.register_event != nil)
	return {allocator = allocator, adapter = adapter}
}

system_destroy :: proc(system: ^System) {
	if system.adapter.destroy != nil {
		system.adapter.destroy(system.adapter.user_data, system.allocator)
	}
	for action in system.button_actions do delete(action.name, system.allocator)
	for action in system.axis_2d_actions do delete(action.name, system.allocator)
	delete(system.button_actions)
	delete(system.axis_2d_actions)
	delete(system.key_bindings)
	delete(system.mouse_button_bindings)
	delete(system.button_axis_2d_bindings)
	system^ = {}
}

add_button :: proc(system: ^System, name: string) -> Button_Action {
	assert(system.allocator.procedure != nil)
	context.allocator = system.allocator
	owned_name, err := strings.clone(name)
	assert(err == nil)

	action := Button_Action(len(system.button_actions))
	append_elem(&system.button_actions, Button_Action_Data{name = owned_name})
	return action
}

add_axis_2d :: proc(system: ^System, name: string) -> Axis_2D_Action {
	assert(system.allocator.procedure != nil)
	context.allocator = system.allocator
	owned_name, err := strings.clone(name)
	assert(err == nil)

	action := Axis_2D_Action(len(system.axis_2d_actions))
	append_elem(
		&system.axis_2d_actions,
		Axis_2D_Action_Data{name = owned_name, owner_binding = -1},
	)
	return action
}

update :: proc(system: ^System) {
	assert(system != nil)
	system.frame_index += 1

	for &action in system.button_actions {
		action.previous_down = action.state.down
		action.state.pressed = false
		action.state.released = false
	}

	for &action in system.axis_2d_actions {
		action.state.previous = action.state.value
		action.state.changed = false
	}

	if system.adapter.update != nil {
		system.adapter.update(system.adapter.user_data, system)
	}

	system.mouse.buttons = system.mouse_buttons
	system.mouse.position = system.mouse_position
	system.mouse.delta = system.pending_mouse_delta
	system.mouse.wheel = system.pending_mouse_wheel
	system.pending_mouse_delta = {}
	system.pending_mouse_wheel = {}

	resolve_buttons(system)
	resolve_axis_2d(system)
}

key_set :: proc(system: ^System, key: Key, down: bool) {
	if !key_is_valid(key) do return
	system.keys[int(key)] = down
}

keyboard_reset :: proc(system: ^System) {
	for &down in system.keys do down = false
}

mouse_set_button :: proc(system: ^System, button: Mouse_Button, down: bool) {
	if !mouse_button_is_valid(button) do return
	system.mouse_buttons[int(button)] = down
}

mouse_move :: proc(system: ^System, position, delta: [2]f32) {
	system.mouse_position = position
	system.pending_mouse_delta += delta
}

mouse_scroll :: proc(system: ^System, wheel: [2]f32) {
	system.pending_mouse_wheel += wheel
}

mouse_reset :: proc(system: ^System) {
	for &down in system.mouse_buttons do down = false
	system.pending_mouse_delta = {}
	system.pending_mouse_wheel = {}
}

button_state :: proc(system: ^System, action: Button_Action) -> Button_State {
	assert(system.frame_index > 0)
	assert(button_action_is_valid(system, action))
	return system.button_actions[int(action)].state
}

down :: proc(system: ^System, action: Button_Action) -> bool {
	return button_state(system, action).down
}

pressed :: proc(system: ^System, action: Button_Action) -> bool {
	return button_state(system, action).pressed
}

released :: proc(system: ^System, action: Button_Action) -> bool {
	return button_state(system, action).released
}

axis_2d_state :: proc(system: ^System, action: Axis_2D_Action) -> Axis_2D_State {
	assert(system.frame_index > 0)
	assert(axis_2d_action_is_valid(system, action))
	return system.axis_2d_actions[int(action)].state
}

axis_2d :: proc(system: ^System, action: Axis_2D_Action) -> [2]f32 {
	return axis_2d_state(system, action).value
}

axis_2d_changed :: proc(system: ^System, action: Axis_2D_Action) -> bool {
	return axis_2d_state(system, action).changed
}

mouse_state :: proc(system: ^System) -> Mouse_State {
	assert(system.frame_index > 0)
	return system.mouse
}

mouse_down :: proc(system: ^System, button: Mouse_Button) -> bool {
	assert(mouse_button_is_valid(button))
	return mouse_state(system).buttons[int(button)]
}

mouse_position :: proc(system: ^System) -> [2]f32 {
	return mouse_state(system).position
}

mouse_delta :: proc(system: ^System) -> [2]f32 {
	return mouse_state(system).delta
}

mouse_wheel :: proc(system: ^System) -> [2]f32 {
	return mouse_state(system).wheel
}

button_action_is_valid :: proc(system: ^System, action: Button_Action) -> bool {
	index := int(action)
	return index >= 0 && index < len(system.button_actions)
}

axis_2d_action_is_valid :: proc(system: ^System, action: Axis_2D_Action) -> bool {
	index := int(action)
	return index >= 0 && index < len(system.axis_2d_actions)
}

key_is_valid :: proc(key: Key) -> bool {
	value := int(key)
	return(
		value >= 4 && value <= 164 ||
		value >= 176 && value <= 221 ||
		value >= 224 && value <= 231 ||
		value >= 257 && value <= 290 \
	)
}

mouse_button_is_valid :: proc(button: Mouse_Button) -> bool {
	return button > .Unknown && button < .Count
}
