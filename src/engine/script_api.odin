package engine

import "base:runtime"
import "core:log"
import "core:math/linalg"
import "core:strings"
import "core:time"
import "input"
import luajit "luajit"

// C ABI function table handed to engine.lua (plan.md 4.1). Plain layout; engine.lua checks
// every member offset against this struct at load (see script_push_layout).
Script_API :: struct {
	version:         u32,
	actor_valid:     proc "c" (index, generation: u32) -> bool,
	actor_transform: proc "c" (index, generation: u32) -> ^Transform,
	actor_destroy:   proc "c" (index, generation: u32),
	actor_find:      proc "c" (name: cstring, out: ^Actor_Id),
	actor_prop:      proc "c" (index, generation: u32, name: cstring) -> rawptr, // Prop pointer by exposed name; nil if absent
	spawn_model:     proc "c" (path: cstring, x, y, z: f32, out: ^Actor_Id),
	input_button:    proc "c" (name: cstring) -> i32,
	input_down:      proc "c" (action: i32) -> bool,
	input_pressed:   proc "c" (action: i32) -> bool,
	mouse:           proc "c" (out: ^[2]f32),
	hud_text:        proc "c" (text: cstring, x, y: f32),
	log:             proc "c" (level: i32, msg: cstring), // 0 debug, 1 info, 2 warn, else error
	camera_position: proc "c" (out: ^[3]f32), // World position of the camera; zeros with no ctx bound
}

SCRIPT_API_VERSION :: 1

// Read by the thunks below. One world per host: script_bind sets them before scripts run.
@(private = "file")
script_world: ^World
@(private = "file")
script_inputs: ^input.System
// Context of the script_bind caller (the engine's allocator and logger). Thunks run under it:
// a fresh default context would free props with the wrong allocator.
@(private = "file")
script_context: runtime.Context
// Camera source for camera_position; nil until script_bind gets a ctx.
@(private = "file")
script_ctx: ^Context

script_api_table := Script_API {
	version         = SCRIPT_API_VERSION,
	actor_valid     = script_api_actor_valid,
	actor_transform = script_api_actor_transform,
	actor_destroy   = script_api_actor_destroy,
	actor_find      = script_api_actor_find,
	actor_prop      = script_api_actor_prop,
	spawn_model     = script_api_spawn_model,
	input_button    = script_api_input_button,
	input_down      = script_api_input_down,
	input_pressed   = script_api_input_pressed,
	mouse           = script_api_mouse,
	hud_text        = script_api_hud_text,
	log             = script_api_log,
	camera_position = script_api_camera_position,
}

// Binds the thunks to one world, its input system and the camera source ctx (nil: camera reads zeros).
// Scripts act on the world bound last.
script_bind :: proc(world: ^World, inputs: ^input.System, ctx: ^Context = nil) {
	script_world = world
	script_inputs = inputs
	script_context = context
	script_ctx = ctx
}

// Clears the bound world when it is world, so thunks and script_reload_all see no world after world_destroy.
script_unbind :: proc(world: ^World) {
	if script_world != world do return
	script_world = nil
	script_inputs = nil
	script_ctx = nil
}

// Frame time of the bound world's script host in ms, reset to zero; ok is false with no host bound.
// Read once per frame by the F1 stats.
script_take_frame_ms :: proc() -> (ms: f32, ok: bool) {
	if script_world == nil || script_world.scripts == nil do return 0, false
	host := script_world.scripts
	ms = f32(time.duration_milliseconds(host.frame_time))
	host.frame_time = 0
	return ms, true
}

// Reloads every module of the world bound by script_bind, as F5 does. One world per host: the
// last script_bind wins. world_destroy unbinds its world, so this is a no-op while nothing is bound.
script_reload_all :: proc() {
	if script_world != nil do script_reload_check(script_world, true)
}

script_input_ready :: proc() -> bool {
	return script_inputs != nil && script_inputs.frame_index > 0
}

script_button_ready :: proc(action: i32) -> bool {
	return script_input_ready() && input.button_action_is_valid(script_inputs, input.Button_Action(action))
}

script_api_actor_valid :: proc "c" (index, generation: u32) -> bool {
	context = script_context
	return script_world != nil && world_valid(script_world, Actor_Id{index, generation})
}

script_api_actor_transform :: proc "c" (index, generation: u32) -> ^Transform {
	context = script_context
	if script_world == nil do return nil
	return actor_transform(script_world, Actor_Id{index, generation})
}

script_api_actor_destroy :: proc "c" (index, generation: u32) {
	context = script_context
	if script_world == nil do return
	world_destroy_actor(script_world, Actor_Id{index, generation})
}

script_api_actor_find :: proc "c" (name: cstring, out: ^Actor_Id) {
	context = script_context
	if out == nil do return
	out^ = {}
	if script_world == nil do return
	id, _ := world_find_by_name(script_world, string(name))
	out^ = id
}

script_api_actor_prop :: proc "c" (index, generation: u32, name: cstring) -> rawptr {
	context = script_context
	id := Actor_Id{index, generation}
	if script_world == nil || script_world.scripts == nil do return nil
	typ, found := script_world.scripts.exposed[string(name)]
	if !found || !world_valid(script_world, id) do return nil
	for block in script_world.slots[id.index].props do if block.type == typ do return block.data
	return nil
}

script_api_spawn_model :: proc "c" (path: cstring, x, y, z: f32, out: ^Actor_Id) {
	context = script_context
	if out == nil do return
	out^ = {}
	if script_world == nil do return
	model_path := script_intern(script_host_get(script_world), string(path))
	out^ = spawn(script_world, Model{path = model_path}, Transform{position = {x, y, z}})
}

script_api_input_button :: proc "c" (name: cstring) -> i32 {
	context = script_context
	if script_inputs == nil do return -1
	for action, index in script_inputs.button_actions do if action.name == string(name) do return i32(index)
	return -1
}

script_api_input_down :: proc "c" (action: i32) -> bool {
	context = script_context
	if !script_button_ready(action) do return false
	return input.down(script_inputs, input.Button_Action(action))
}

script_api_input_pressed :: proc "c" (action: i32) -> bool {
	context = script_context
	if !script_button_ready(action) do return false
	return input.pressed(script_inputs, input.Button_Action(action))
}

script_api_mouse :: proc "c" (out: ^[2]f32) {
	context = script_context
	if out == nil || !script_input_ready() do return
	out^ = input.mouse_position(script_inputs)
}

script_api_hud_text :: proc "c" (text: cstring, x, y: f32) {
	context = script_context
	if script_world == nil do return
	world_text(script_world, string(text), {x, y})
}

script_api_log :: proc "c" (level: i32, msg: cstring) {
	context = script_context
	switch level {
	case 0: log.debugf("script: %s", string(msg))
	case 1: log.infof("script: %s", string(msg))
	case 2: log.warnf("script: %s", string(msg))
	case: log.errorf("script: %s", string(msg))
	}
}

script_api_camera_position :: proc "c" (out: ^[3]f32) {
	context = script_context
	if out == nil do return
	out^ = {}
	if script_ctx == nil do return
	out^ = camera_position(script_ctx)
}

// Sizes and offsets engine.lua checks with ffi.sizeof / ffi.offsetof. Keys: "Type" or "Type.field".
script_push_layout :: proc(L: ^luajit.State) {
	luajit.createtable(L, 0, 32)
	set :: proc(L: ^luajit.State, key: cstring, value: int) {
		luajit.pushinteger(L, value)
		luajit.setfield(L, -2, key)
	}
	set(L, "Vec3", size_of(Vec3))
	set(L, "Quat", size_of(linalg.Quaternionf32))
	set(L, "Transform", size_of(Transform))
	set(L, "Transform.position", int(offset_of(Transform, position)))
	set(L, "Transform.rotation", int(offset_of(Transform, rotation)))
	set(L, "Transform.scale", int(offset_of(Transform, scale)))
	set(L, "Actor", size_of(Actor_Id))
	set(L, "ScriptAPI", size_of(Script_API))
	set(L, "ScriptAPI.version", int(offset_of(Script_API, version)))
	set(L, "ScriptAPI.actor_valid", int(offset_of(Script_API, actor_valid)))
	set(L, "ScriptAPI.actor_transform", int(offset_of(Script_API, actor_transform)))
	set(L, "ScriptAPI.actor_destroy", int(offset_of(Script_API, actor_destroy)))
	set(L, "ScriptAPI.actor_find", int(offset_of(Script_API, actor_find)))
	set(L, "ScriptAPI.actor_prop", int(offset_of(Script_API, actor_prop)))
	set(L, "ScriptAPI.spawn_model", int(offset_of(Script_API, spawn_model)))
	set(L, "ScriptAPI.input_button", int(offset_of(Script_API, input_button)))
	set(L, "ScriptAPI.input_down", int(offset_of(Script_API, input_down)))
	set(L, "ScriptAPI.input_pressed", int(offset_of(Script_API, input_pressed)))
	set(L, "ScriptAPI.mouse", int(offset_of(Script_API, mouse)))
	set(L, "ScriptAPI.hud_text", int(offset_of(Script_API, hud_text)))
	set(L, "ScriptAPI.log", int(offset_of(Script_API, log)))
	set(L, "ScriptAPI.camera_position", int(offset_of(Script_API, camera_position)))
}

// Exposes Prop type T to Lua under name. cdef must define the C struct `name` (LuaJIT side);
// its size must equal size_of(T), else nothing is exposed. False on error (logged).
script_expose :: proc(world: ^World, T: typeid, name: string, cdef: cstring) -> bool {
	host := script_host_get(world)
	if !host.ready {
		log.errorf("script_expose %q: engine.lua not loaded", name)
		return false
	}
	if prev, found := host.exposed[name]; found {
		if prev == T do return true
		log.errorf("script_expose %q: already exposed as another type", name)
		return false
	}
	L := host.L
	top := luajit.gettop(L)
	defer luajit.settop(L, top)
	luajit.rawgeti(L, luajit.REGISTRYINDEX, host.handler) // top+1
	luajit.rawgeti(L, luajit.REGISTRYINDEX, host.expose) // top+2
	luajit.pushstring(L, cdef)
	luajit.pushstring(L, strings.clone_to_cstring(name, context.temp_allocator))
	luajit.pushinteger(L, type_info_of(T).size)
	if luajit.pcall(L, 3, 0, top+1) != luajit.LUA_OK {
		log.errorf("script_expose %q: %s", name, luajit.tostring(L, -1))
		return false
	}
	host.exposed[strings.clone(name)] = T
	return true
}
