package engine

import "core:log"
import "core:math/linalg"
import "core:strings"
import "core:time"
import "input"
import luajit "luajit"

// C ABI function table handed to engine.lua (luajit-design.md 4.1). Plain layout; engine.lua checks
// every member offset against this struct at load (see script_push_layout). Each function takes the
// Script_Host pointer first: engine.lua passes it back on every call, so no package-level world state.
Script_API :: struct {
	version:         u32,
	actor_valid:     proc "c" (host: rawptr, index, generation: u32) -> bool,
	actor_transform: proc "c" (host: rawptr, index, generation: u32) -> ^Transform,
	actor_destroy:   proc "c" (host: rawptr, index, generation: u32),
	actor_find:      proc "c" (host: rawptr, name: cstring, out: ^Actor_Id),
	actor_prop:      proc "c" (host: rawptr, index, generation: u32, name: cstring) -> rawptr, // Prop pointer by exposed name; nil if absent
	spawn_model:     proc "c" (host: rawptr, path: cstring, x, y, z: f32, out: ^Actor_Id),
	input_button:    proc "c" (host: rawptr, name: cstring) -> i32,
	input_down:      proc "c" (host: rawptr, action: i32) -> bool,
	input_pressed:   proc "c" (host: rawptr, action: i32) -> bool,
	mouse:           proc "c" (host: rawptr, out: ^[2]f32),
	hud_text:        proc "c" (host: rawptr, text: cstring, x, y: f32),
	log:             proc "c" (host: rawptr, level: i32, msg: cstring), // 0 debug, 1 info, 2 warn, else error
	camera_position: proc "c" (host: rawptr, out: ^[3]f32), // World position of the camera; zeros with no ctx bound
	// P4 scalar surface. Every thunk takes the host first, validates actor ids (no-op when stale) and
	// writes through the World; camera and environment setters act on the first live actor with that Prop.
	actor_set_scale:           proc "c" (host: rawptr, index, generation: u32, sx, sy, sz: f32),
	actor_add_box_collider:    proc "c" (host: rawptr, index, generation: u32, hx, hy, hz: f32, is_static: bool),
	actor_add_sphere_collider: proc "c" (host: rawptr, index, generation: u32, radius: f32),
	actor_set_name:            proc "c" (host: rawptr, index, generation: u32, name: cstring),
	camera_look_at:            proc "c" (host: rawptr, x, y, z: f32) -> bool, // false: no live Camera
	camera_set_fov:            proc "c" (host: rawptr, fov_y: f32) -> bool,
	set_fog:                   proc "c" (host: rawptr, r, g, b, distance: f32) -> bool, // false: no live Environment
	clear_fog:                 proc "c" (host: rawptr) -> bool,
	set_sun:                   proc "c" (host: rawptr, x, y, z: f32) -> bool,
	set_shadows:               proc "c" (host: rawptr, on: bool) -> bool,
	hud_text_color:            proc "c" (host: rawptr, text: cstring, x, y, r, g, b, a: f32), // colour is sRGB rgba
	window_size:               proc "c" (host: rawptr, out: ^[2]f32), // window px; zeros with no Device
	scene_time:                proc "c" (host: rawptr) -> f32, // World.time: seconds accumulated by world_update
}

script_api_actor_set_scale :: proc "c" (host: rawptr, index, generation: u32, sx, sy, sz: f32) {
	h := (^Script_Host)(host)
	context = h.run_context
	id := Actor_Id{index, generation}
	if h.world == nil || !world_valid(h.world, id) do return
	actor_transform(h.world, id).scale = {sx, sy, sz}
}

script_api_actor_add_box_collider :: proc "c" (host: rawptr, index, generation: u32, hx, hy, hz: f32, is_static: bool) {
	h := (^Script_Host)(host)
	context = h.run_context
	id := Actor_Id{index, generation}
	if h.world == nil || !world_valid(h.world, id) do return
	body := Body_Kind.Static if is_static else .Dynamic
	actor_add_props(h.world, id, Collider{shape = Box{half = {hx, hy, hz}}, body = body})
}

script_api_actor_add_sphere_collider :: proc "c" (host: rawptr, index, generation: u32, radius: f32) {
	h := (^Script_Host)(host)
	context = h.run_context
	id := Actor_Id{index, generation}
	if h.world == nil || !world_valid(h.world, id) do return
	actor_add_props(h.world, id, Collider{shape = Sphere{radius = radius}})
}

script_api_actor_set_name :: proc "c" (host: rawptr, index, generation: u32, name: cstring) {
	h := (^Script_Host)(host)
	context = h.run_context
	id := Actor_Id{index, generation}
	if h.world == nil || !world_valid(h.world, id) do return
	actor_add_props(h.world, id, Name{value = string(name)}) // name_added clones the string
}

// First live actor with a Prop of type T, nil if none. Camera and Environment setters act on it.
script_first_prop :: proc(world: ^World, $T: typeid) -> ^T {
	for &slot in world.slots do if slot.alive {
		if prop := slot_component(&slot, T); prop != nil do return prop
	}
	return nil
}

script_api_camera_look_at :: proc "c" (host: rawptr, x, y, z: f32) -> bool {
	h := (^Script_Host)(host)
	context = h.run_context
	if h.world == nil do return false
	camera := script_first_prop(h.world, Camera)
	if camera == nil do return false
	camera.look_at = Vec3{x, y, z}
	return true
}

script_api_camera_set_fov :: proc "c" (host: rawptr, fov_y: f32) -> bool {
	h := (^Script_Host)(host)
	context = h.run_context
	if h.world == nil do return false
	camera := script_first_prop(h.world, Camera)
	if camera == nil do return false
	camera.fov_y = fov_y
	return true
}

script_api_set_fog :: proc "c" (host: rawptr, r, g, b, distance: f32) -> bool {
	h := (^Script_Host)(host)
	context = h.run_context
	if h.world == nil do return false
	env := script_first_prop(h.world, Environment)
	if env == nil do return false
	env.fog = Fog{color = {r, g, b}, distance = distance}
	return true
}

script_api_clear_fog :: proc "c" (host: rawptr) -> bool {
	h := (^Script_Host)(host)
	context = h.run_context
	if h.world == nil do return false
	env := script_first_prop(h.world, Environment)
	if env == nil do return false
	env.fog = nil
	return true
}

script_api_set_sun :: proc "c" (host: rawptr, x, y, z: f32) -> bool {
	h := (^Script_Host)(host)
	context = h.run_context
	if h.world == nil do return false
	env := script_first_prop(h.world, Environment)
	if env == nil do return false
	env.sun_direction = Vec3{x, y, z}
	return true
}

script_api_set_shadows :: proc "c" (host: rawptr, on: bool) -> bool {
	h := (^Script_Host)(host)
	context = h.run_context
	if h.world == nil do return false
	env := script_first_prop(h.world, Environment)
	if env == nil do return false
	env.shadows = on
	return true
}

script_api_hud_text_color :: proc "c" (host: rawptr, text: cstring, x, y, r, g, b, a: f32) {
	h := (^Script_Host)(host)
	context = h.run_context
	if h.world == nil do return
	world_text(h.world, string(text), {x, y}, {r, g, b, a})
}

script_api_window_size :: proc "c" (host: rawptr, out: ^[2]f32) {
	h := (^Script_Host)(host)
	context = h.run_context
	if out == nil do return
	out^ = {}
	if h.world == nil || h.world.gfx_ctx == nil do return
	size := h.world.gfx_ctx.window_size
	out^ = {f32(size.x), f32(size.y)}
}

script_api_scene_time :: proc "c" (host: rawptr) -> f32 {
	h := (^Script_Host)(host)
	context = h.run_context
	if h.world == nil do return 0
	return h.world.time
}

SCRIPT_API_VERSION :: 1

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

	actor_set_scale           = script_api_actor_set_scale,
	actor_add_box_collider    = script_api_actor_add_box_collider,
	actor_add_sphere_collider = script_api_actor_add_sphere_collider,
	actor_set_name            = script_api_actor_set_name,
	camera_look_at            = script_api_camera_look_at,
	camera_set_fov            = script_api_camera_set_fov,
	set_fog                   = script_api_set_fog,
	clear_fog                 = script_api_clear_fog,
	set_sun                   = script_api_set_sun,
	set_shadows               = script_api_set_shadows,
	hud_text_color            = script_api_hud_text_color,
	window_size               = script_api_window_size,
	scene_time                = script_api_scene_time,
}

// Binds host (created on demand) to world, its input system and the camera source ctx (nil: camera reads zeros).
// Thunks of that host act on that world only; other worlds keep their own host.
script_bind :: proc(world: ^World, inputs: ^input.System, ctx: ^Context = nil) {
	host := script_host_get(world)
	host.world = world
	host.inputs = inputs
	host.camera = ctx
	host.run_context = context
}

// Frame time of all live script hosts in ms, each reset to zero; ok is false with no host alive.
// Read once per frame by the F1 stats.
script_take_frame_ms :: proc() -> (ms: f32, ok: bool) {
	for host in script_hosts {
		ok = true
		ms += f32(time.duration_milliseconds(host.frame_time))
		host.frame_time = 0
	}
	return
}

// Reloads every module of every live script host with a world, as F5 does.
script_reload_all :: proc() {
	for h in script_hosts do if h.world != nil do script_reload_check(h.world, true)
}

script_input_ready :: proc(h: ^Script_Host) -> bool {
	return h.inputs != nil && h.inputs.frame_index > 0
}

script_button_ready :: proc(h: ^Script_Host, action: i32) -> bool {
	return script_input_ready(h) && input.button_action_is_valid(h.inputs, input.Button_Action(action))
}

script_api_actor_valid :: proc "c" (host: rawptr, index, generation: u32) -> bool {
	h := (^Script_Host)(host)
	context = h.run_context
	return h.world != nil && world_valid(h.world, Actor_Id{index, generation})
}

script_api_actor_transform :: proc "c" (host: rawptr, index, generation: u32) -> ^Transform {
	h := (^Script_Host)(host)
	context = h.run_context
	if h.world == nil do return nil
	return actor_transform(h.world, Actor_Id{index, generation})
}

script_api_actor_destroy :: proc "c" (host: rawptr, index, generation: u32) {
	h := (^Script_Host)(host)
	context = h.run_context
	if h.world == nil do return
	world_destroy_actor(h.world, Actor_Id{index, generation})
}

script_api_actor_find :: proc "c" (host: rawptr, name: cstring, out: ^Actor_Id) {
	h := (^Script_Host)(host)
	context = h.run_context
	if out == nil do return
	out^ = {}
	if h.world == nil do return
	id, _ := world_find_by_name(h.world, string(name))
	out^ = id
}

script_api_actor_prop :: proc "c" (host: rawptr, index, generation: u32, name: cstring) -> rawptr {
	h := (^Script_Host)(host)
	context = h.run_context
	id := Actor_Id{index, generation}
	if h.world == nil do return nil
	typ, found := h.exposed[string(name)]
	if !found || !world_valid(h.world, id) do return nil
	for block in h.world.slots[id.index].props do if block.type == typ do return block.data
	return nil
}

script_api_spawn_model :: proc "c" (host: rawptr, path: cstring, x, y, z: f32, out: ^Actor_Id) {
	h := (^Script_Host)(host)
	context = h.run_context
	if out == nil do return
	out^ = {}
	if h.world == nil do return
	model_path := script_intern(h, string(path))
	out^ = spawn(h.world, Model{path = model_path}, Transform{position = {x, y, z}})
}

script_api_input_button :: proc "c" (host: rawptr, name: cstring) -> i32 {
	h := (^Script_Host)(host)
	context = h.run_context
	if h.inputs == nil do return -1
	for action, index in h.inputs.button_actions do if action.name == string(name) do return i32(index)
	return -1
}

script_api_input_down :: proc "c" (host: rawptr, action: i32) -> bool {
	h := (^Script_Host)(host)
	context = h.run_context
	if !script_button_ready(h, action) do return false
	return input.down(h.inputs, input.Button_Action(action))
}

script_api_input_pressed :: proc "c" (host: rawptr, action: i32) -> bool {
	h := (^Script_Host)(host)
	context = h.run_context
	if !script_button_ready(h, action) do return false
	return input.pressed(h.inputs, input.Button_Action(action))
}

script_api_mouse :: proc "c" (host: rawptr, out: ^[2]f32) {
	h := (^Script_Host)(host)
	context = h.run_context
	if out == nil || !script_input_ready(h) do return
	out^ = input.mouse_position(h.inputs)
}

script_api_hud_text :: proc "c" (host: rawptr, text: cstring, x, y: f32) {
	h := (^Script_Host)(host)
	context = h.run_context
	if h.world == nil do return
	world_text(h.world, string(text), {x, y})
}

script_api_log :: proc "c" (host: rawptr, level: i32, msg: cstring) {
	h := (^Script_Host)(host)
	context = h.run_context
	switch level {
	case 0: log.debugf("script: %s", string(msg))
	case 1: log.infof("script: %s", string(msg))
	case 2: log.warnf("script: %s", string(msg))
	case: log.errorf("script: %s", string(msg))
	}
}

script_api_camera_position :: proc "c" (host: rawptr, out: ^[3]f32) {
	h := (^Script_Host)(host)
	context = h.run_context
	if out == nil do return
	out^ = {}
	if h.camera == nil do return
	out^ = camera_position(h.camera)
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
	set(L, "ScriptAPI.actor_set_scale", int(offset_of(Script_API, actor_set_scale)))
	set(L, "ScriptAPI.actor_add_box_collider", int(offset_of(Script_API, actor_add_box_collider)))
	set(L, "ScriptAPI.actor_add_sphere_collider", int(offset_of(Script_API, actor_add_sphere_collider)))
	set(L, "ScriptAPI.actor_set_name", int(offset_of(Script_API, actor_set_name)))
	set(L, "ScriptAPI.camera_look_at", int(offset_of(Script_API, camera_look_at)))
	set(L, "ScriptAPI.camera_set_fov", int(offset_of(Script_API, camera_set_fov)))
	set(L, "ScriptAPI.set_fog", int(offset_of(Script_API, set_fog)))
	set(L, "ScriptAPI.clear_fog", int(offset_of(Script_API, clear_fog)))
	set(L, "ScriptAPI.set_sun", int(offset_of(Script_API, set_sun)))
	set(L, "ScriptAPI.set_shadows", int(offset_of(Script_API, set_shadows)))
	set(L, "ScriptAPI.hud_text_color", int(offset_of(Script_API, hud_text_color)))
	set(L, "ScriptAPI.window_size", int(offset_of(Script_API, window_size)))
	set(L, "ScriptAPI.scene_time", int(offset_of(Script_API, scene_time)))
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

// Sets engine.config[name] on this World's script host. Scripts copy it at load; a missing key is their load error.
// False when engine.lua is not loaded (logged).
script_set_config :: proc(world: ^World, name: string, value: f64) -> bool {
	host := script_host_get(world)
	if !host.ready {
		log.errorf("script_set_config %q: engine.lua not loaded", name)
		return false
	}
	L := host.L
	top := luajit.gettop(L)
	defer luajit.settop(L, top)
	luajit.rawgeti(L, luajit.REGISTRYINDEX, host.config) // top+1
	luajit.pushnumber(L, luajit.Number(value))
	luajit.setfield(L, -2, strings.clone_to_cstring(name, context.temp_allocator))
	return true
}
