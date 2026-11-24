package engine

import "core:c"
import "core:log"
import "core:os"
import "core:strings"
import "core:time"
import luajit "luajit"

LUA_TTABLE :: 5
LUA_TFUNCTION :: 6
LUA_NOREF :: -2

// Error handler: appends a traceback to the message of every protected call.
HANDLER_SRC :: "return function(e) return debug.traceback(tostring(e), 2) end"

// Returns make_actor(index, generation) -> Actor cdata. The Actor cdef lives in engine.lua. jit.off: called from a C pcall, a trace of it aborts (NYI return to lower frame); create-time only, so interpreted is fine.
BOOTSTRAP_SRC :: "local ffi = require('ffi'); local Actor = ffi.typeof('Actor'); local make = function(i, g) return Actor(i, g) end; jit.off(make); return make"

// Wall time between hot reload checks started by world_update.
SCRIPT_RELOAD_INTERVAL :: 250 * time.Millisecond

// Per-frame time budget of script_gc_step; the Lua collector runs only inside it.
SCRIPT_GC_BUDGET :: 200 * time.Microsecond
// Hard cap on GC steps per frame, so a budget that never runs out still ends.
SCRIPT_GC_MAX_STEPS :: 256

// Failed load of a module: the path as given (owned) and the file mtime of the last attempt.
Failed_Load :: struct {
	path:  string,
	mtime: time.Time,
}

// One LuaJIT state per World, created on the first Script. modules: keys are script_path_key(path), owned;
// values are heap blocks, so Script.module stays valid while the map grows.
// failed: keys are script_path_key(path), owned; values hold the path as given and the last attempt's mtime.
Script_Host :: struct {
	L:          ^luajit.State,
	modules:    map[string]^Script_Module,
	failed:     map[string]Failed_Load,
	paths:      map[string]string, // Model paths from spawn_model: key == value, owned, freed in destroy
	exposed:    map[string]typeid, // script_expose names -> Prop types; keys owned, freed in destroy
	handler:    c.int, // registry ref of the traceback handler
	make_actor: c.int, // registry ref of the Actor constructor
	expose:     c.int, // registry ref of engine.lua's _expose(cdef, name, size)
	batch_wrap: c.int, // registry ref of engine.lua's _batch(fn) wrapper for batch hooks
	ready:      bool, // engine.lua loaded; false => every script faults at init
	last_poll:  time.Tick, // when script_reload_check last ran from script_host_poll_reload
	gc_budget:  time.Duration, // script_gc_step time per frame
	frame_time: time.Duration, // tick, fixed_tick and gc time since the last script_take_frame_ms
}

script_host_get :: proc(world: ^World) -> ^Script_Host {
	if world.scripts == nil do world.scripts = script_host_create()
	return world.scripts
}

script_host_create :: proc() -> ^Script_Host {
	host := new(Script_Host)
	host.L = luajit.newstate()
	luajit.openlibs(host.L)
	_ = luajit.gc(host.L, luajit.LUA_GCSTOP, 0) // automatic steps would land in random frames; script_gc_step runs them
	host.modules = make(map[string]^Script_Module)
	host.failed = make(map[string]Failed_Load)
	host.paths = make(map[string]string)
	host.exposed = make(map[string]typeid)
	host.last_poll = time.tick_now()
	host.gc_budget = SCRIPT_GC_BUDGET
	host.handler = script_run_chunk(host.L, HANDLER_SRC)
	host.ready = script_load_engine(host)
	if os.get_env("CUBES_JIT_V", context.temp_allocator) == "1" do script_jit_debug_set(host, true)
	host.make_actor = script_run_chunk(host.L, BOOTSTRAP_SRC)
	return host
}

script_host_destroy :: proc(host: ^Script_Host) {
	for key, module in host.modules {
		delete(key)
		delete(module.path)
		delete(module.ids)
		free(module)
	}
	delete(host.modules)
	for key, failure in host.failed {
		delete(key)
		delete(failure.path)
	}
	delete(host.failed)
	for path in host.paths do delete(path)
	delete(host.paths)
	for name in host.exposed do delete(name)
	delete(host.exposed)
	luajit.close(host.L)
	free(host)
}

// Runs a bootstrap chunk that returns one value and keeps it in the registry. Failure is an engine bug.
script_run_chunk :: proc(L: ^luajit.State, src: cstring) -> c.int {
	if luajit.loadstring(L, src) != luajit.LUA_OK || luajit.pcall(L, 0, 1, 0) != luajit.LUA_OK {
		log.panicf("script: bootstrap failed: %s", luajit.tostring(L, -1))
	}
	return luajit.ref(L, luajit.REGISTRYINDEX)
}

// Lua half of the engine API; its layout checks run against script_push_layout at load.
ENGINE_SRC :: #load("script/engine.lua", string)

// Loads engine.lua with the API table and layout; its result becomes package.loaded.engine.
// Failure logs and returns false: every script then faults at init instead of crashing.
script_load_engine :: proc(host: ^Script_Host) -> bool {
	L := host.L
	top := luajit.gettop(L)
	defer luajit.settop(L, top)
	luajit.rawgeti(L, luajit.REGISTRYINDEX, host.handler) // top+1: traceback handler
	src := strings.clone_to_cstring(ENGINE_SRC, context.temp_allocator)
	if luajit.loadstring(L, src) != luajit.LUA_OK {
		log.errorf("script: engine.lua: %s", luajit.tostring(L, -1))
		return false
	}
	luajit.pushlightuserdata(L, rawptr(&script_api_table))
	script_push_layout(L)
	if luajit.pcall(L, 2, 1, top+1) != luajit.LUA_OK {
		log.errorf("script: engine.lua: %s", luajit.tostring(L, -1))
		return false
	}
	luajit.getfield(L, -1, "_expose") // top+2
	host.expose = luajit.ref(L, luajit.REGISTRYINDEX)
	luajit.getfield(L, -1, "_batch") // top+2
	host.batch_wrap = luajit.ref(L, luajit.REGISTRYINDEX)
	luajit.getglobal(L, "package")
	luajit.getfield(L, -1, "loaded")
	luajit.pushvalue(L, -3)
	luajit.setfield(L, -2, "engine")
	return true
}

// Owned copy of a Model path: Model.path is borrowed and must outlive the actor.
script_intern :: proc(host: ^Script_Host, path: string) -> string {
	if owned, found := host.paths[path]; found do return owned
	owned := strings.clone(path)
	host.paths[owned] = owned
	return owned
}

// Map key for a script path: '\\' becomes '/', so both spellings of one file share a key.
// Returns path itself when it has no backslash; otherwise a copy from context.temp_allocator.
script_path_key :: proc(path: string) -> string {
	if !strings.contains_rune(path, '\\') do return path
	buf := make([]u8, len(path), context.temp_allocator)
	for i in 0..<len(path) {
		buf[i] = path[i]
		if path[i] == '\\' do buf[i] = '/'
	}
	return string(buf)
}

// Modification time of path. ok is false when the file cannot be stat'ed (missing).
script_mtime :: proc(path: string) -> (mtime: time.Time, ok: bool) {
	info, err := os.stat(path, context.temp_allocator)
	if err != nil do return {}, false
	defer os.file_info_delete(info, context.temp_allocator)
	return info.modification_time, true
}

// Runs the file at path into a fresh chunk and returns the registry ref of the table it returns.
// Load, run or shape errors are logged and give LUA_NOREF: the caller keeps whatever it had.
script_file_load :: proc(host: ^Script_Host, path: string) -> c.int {
	L := host.L
	top := luajit.gettop(L)
	defer luajit.settop(L, top)
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	luajit.rawgeti(L, luajit.REGISTRYINDEX, host.handler) // top+1: errfunc for pcall below
	if luajit.loadfile(L, cpath) != luajit.LUA_OK {
		log.errorf("script %q: %s", path, luajit.tostring(L, -1))
		return LUA_NOREF
	}
	if luajit.pcall(L, 0, 1, top+1) != luajit.LUA_OK {
		log.errorf("script %q: %s", path, luajit.tostring(L, -1))
		return LUA_NOREF
	}
	if luajit.type(L, -1) != LUA_TTABLE {
		log.errorf("script %q: module must return a table", path)
		return LUA_NOREF
	}
	return luajit.ref(L, luajit.REGISTRYINDEX)
}

// Takes over the module table at table (a registry ref) and resolves its hook refs.
script_module_fill :: proc(host: ^Script_Host, module: ^Script_Module, table: c.int) {
	module.table = table
	module.create = script_module_fn(host, table, "create")
	module.tick = script_module_fn(host, table, "tick")
	module.fixed_tick = script_module_fn(host, table, "fixed_tick")
	module.destroy = script_module_fn(host, table, "destroy")
	module.reload = script_module_fn(host, table, "reload")
	module.batch = script_module_flag(host, table, "batch")
	module.tick_all = script_module_batch_fn(host, table, "tick_all")
	module.fixed_tick_all = script_module_batch_fn(host, table, "fixed_tick_all")
}

// Drops every registry ref of the module. Called when a reload replaces them.
script_module_unref :: proc(host: ^Script_Host, module: ^Script_Module) {
	refs := [?]c.int{module.table, module.create, module.tick, module.fixed_tick, module.destroy, module.reload, module.tick_all, module.fixed_tick_all}
	for ref in refs do if ref > 0 do luajit.unref(host.L, luajit.REGISTRYINDEX, ref)
}

// Loads the module at path once and caches it. A failure is logged and recorded with the file's mtime,
// so the next spawn retries and script_reload_check retries only once the mtime changes.
script_module_load :: proc(host: ^Script_Host, path: string) -> ^Script_Module {
	key := script_path_key(path)
	if module, ok := host.modules[key]; ok do return module
	mtime, _ := script_mtime(path)
	table := script_file_load(host, path)
	if table == LUA_NOREF {
		if failure, found := host.failed[key]; found {
			host.failed[key] = Failed_Load{path = failure.path, mtime = mtime}
		} else {
			host.failed[strings.clone(key)] = Failed_Load{path = strings.clone(path), mtime = mtime}
		}
		return nil
	}
	module := new(Script_Module)
	module.path = strings.clone(path)
	module.mtime = mtime
	script_module_fill(host, module, table)
	host.modules[strings.clone(key)] = module
	if stale, failure := delete_key(&host.failed, key); stale != "" {
		delete(stale)
		delete(failure.path)
	}
	return module
}

// Resolves module[name] to a registry ref; LUA_NOREF when absent or not a function.
script_module_fn :: proc(host: ^Script_Host, table: c.int, name: cstring) -> c.int {
	L := host.L
	luajit.rawgeti(L, luajit.REGISTRYINDEX, table)
	luajit.getfield(L, -1, name)
	fn: c.int = LUA_NOREF
	if luajit.type(L, -1) == LUA_TFUNCTION {
		fn = luajit.ref(L, luajit.REGISTRYINDEX)
	} else {
		luajit.pop(L)
	}
	luajit.pop(L) // the module table
	return fn
}

// Reads a boolean field of module[name]; false when absent.
script_module_flag :: proc(host: ^Script_Host, table: c.int, name: cstring) -> bool {
	L := host.L
	top := luajit.gettop(L)
	defer luajit.settop(L, top)
	luajit.rawgeti(L, luajit.REGISTRYINDEX, table)
	luajit.getfield(L, -1, name)
	return luajit.toboolean(L, -1) != 0
}

// Resolves module[name] and wraps it with engine.lua's _batch, so the hook gets (ids, count, dt).
// LUA_NOREF when absent or when engine.lua failed to load.
script_module_batch_fn :: proc(host: ^Script_Host, table: c.int, name: cstring) -> c.int {
	fn := script_module_fn(host, table, name)
	if fn == LUA_NOREF || !host.ready do return LUA_NOREF
	L := host.L
	top := luajit.gettop(L)
	defer luajit.settop(L, top)
	luajit.rawgeti(L, luajit.REGISTRYINDEX, host.batch_wrap) // top+1
	luajit.rawgeti(L, luajit.REGISTRYINDEX, fn)
	ok := luajit.pcall(L, 1, 1, 0) == luajit.LUA_OK
	luajit.unref(L, luajit.REGISTRYINDEX, fn) // the wrapper closure keeps fn alive
	if !ok {
		log.errorf("script: batch wrapper for %s: %s", name, luajit.tostring(L, -1))
		return LUA_NOREF
	}
	return luajit.ref(L, luajit.REGISTRYINDEX)
}

// Pushes an Actor cdata for id via make_actor. handler_idx is the absolute index of the traceback handler.
// On false the error message is on top of the stack.
script_push_actor :: proc(host: ^Script_Host, id: Actor_Id, handler_idx: c.int) -> bool {
	L := host.L
	luajit.rawgeti(L, luajit.REGISTRYINDEX, host.make_actor)
	luajit.pushnumber(L, luajit.Number(id.index))
	luajit.pushnumber(L, luajit.Number(id.generation))
	return luajit.pcall(L, 2, 1, handler_idx) == luajit.LUA_OK
}

// Gives the actor its Lua table and Actor handle, then runs create. Failure faults the script.
script_init :: proc(world: ^World, id: Actor_Id, self: ^Script) {
	host := script_host_get(world)
	if !host.ready {
		self.faulted = true
		return
	}
	module := script_module_load(host, self.path)
	if module == nil {
		self.faulted = true
		return
	}
	self.module = module
	L := host.L
	top := luajit.gettop(L)
	defer luajit.settop(L, top)
	luajit.rawgeti(L, luajit.REGISTRYINDEX, host.handler) // top+1
	luajit.createtable(L, 0, 0)
	self.self_ref = luajit.ref(L, luajit.REGISTRYINDEX)
	if !script_push_actor(host, id, top+1) {
		log.errorf("script %q: actor handle: %s", self.path, luajit.tostring(L, -1))
		self.faulted = true
		return
	}
	self.actor_ref = luajit.ref(L, luajit.REGISTRYINDEX)
	if module.create != LUA_NOREF do script_invoke(world, id, self, module.create, "create")
}

// Runs destroy (if the script is healthy), then drops the actor's refs.
script_release :: proc(world: ^World, id: Actor_Id, self: ^Script) {
	host := world.scripts
	if self.module != nil && !self.faulted && self.module.destroy != LUA_NOREF {
		script_invoke(world, id, self, self.module.destroy, "destroy")
	}
	if self.self_ref != 0 do luajit.unref(host.L, luajit.REGISTRYINDEX, self.self_ref)
	if self.actor_ref != 0 do luajit.unref(host.L, luajit.REGISTRYINDEX, self.actor_ref)
	self.self_ref = 0
	self.actor_ref = 0
}

// Calls fn(self, actor [, dt]) under the traceback handler. script is read only before the call:
// a hook may destroy its own actor, which frees the Script prop.
script_invoke :: proc(world: ^World, id: Actor_Id, script: ^Script, fn: c.int, what: cstring, dt: Maybe(f32) = nil) {
	host := world.scripts
	L := host.L
	top := luajit.gettop(L)
	luajit.rawgeti(L, luajit.REGISTRYINDEX, host.handler) // top+1
	luajit.rawgeti(L, luajit.REGISTRYINDEX, fn)
	luajit.rawgeti(L, luajit.REGISTRYINDEX, script.self_ref)
	luajit.rawgeti(L, luajit.REGISTRYINDEX, script.actor_ref)
	nargs: c.int = 2
	if d, ok := dt.?; ok {
		luajit.pushnumber(L, luajit.Number(d))
		nargs += 1
	}
	_ = script_finish(world, id, script.path, top, nargs, what)
}

// Protected call of the function sitting above the handler at top+2, with nargs arguments.
// path is copied by the caller before the call: the actor may be gone when an error lands.
// Logs; faults the script only if its actor is still alive (re-lookup), then restores top.
script_finish :: proc(world: ^World, id: Actor_Id, path: string, top, nargs: c.int, what: cstring) -> bool {
	L := world.scripts.L
	if luajit.pcall(L, nargs, 0, top+1) == luajit.LUA_OK {
		luajit.settop(L, top)
		return true
	}
	log.errorf("script %q: %s: %s", path, what, luajit.tostring(L, -1))
	// Re-lookup: the hook may have destroyed its own actor, freeing the Script prop.
	if script := actor_props(world, id, Script); script != nil do script.faulted = true
	luajit.settop(L, top)
	return false
}

// Pushes one script_call argument. Actor_Id becomes an Actor cdata. False on a failed make_actor, error left on top.
script_push_arg :: proc(host: ^Script_Host, arg: any, handler_idx: c.int) -> bool {
	L := host.L
	switch v in arg {
	case f32:
		luajit.pushnumber(L, luajit.Number(v))
	case f64:
		luajit.pushnumber(L, luajit.Number(v))
	case i32:
		luajit.pushnumber(L, luajit.Number(v))
	case int:
		luajit.pushnumber(L, luajit.Number(v))
	case bool:
		luajit.pushboolean(L, c.int(v))
	case string:
		luajit.pushlstring(L, raw_data(v), len(v))
	case Actor_Id:
		return script_push_actor(host, v, handler_idx)
	case:
		assert(false, "script_call: unsupported argument type")
		luajit.pushnil(L)
	}
	return true
}

// Calls the named function of the actor's module with args. False when the actor has no
// usable script or the function is missing. A runtime error logs and faults the script.
script_call :: proc(world: ^World, id: Actor_Id, name: cstring, args: ..any) -> bool {
	script := actor_props(world, id, Script)
	if script == nil || script.faulted || script.module == nil || world.scripts == nil do return false
	host := world.scripts
	L := host.L
	top := luajit.gettop(L)
	luajit.rawgeti(L, luajit.REGISTRYINDEX, host.handler) // top+1
	luajit.rawgeti(L, luajit.REGISTRYINDEX, script.module.table)
	luajit.getfield(L, -1, name)
	if luajit.type(L, -1) != LUA_TFUNCTION {
		luajit.settop(L, top)
		return false
	}
	luajit.remove(L, -2) // drop the module table, leaving the function
	luajit.rawgeti(L, luajit.REGISTRYINDEX, script.self_ref)
	luajit.rawgeti(L, luajit.REGISTRYINDEX, script.actor_ref)
	for arg in args {
		if !script_push_arg(host, arg, top+1) {
			log.errorf("script %q: %s: argument: %s", script.path, name, luajit.tostring(L, -1))
			luajit.settop(L, top)
			return false
		}
	}
	return script_finish(world, id, script.path, top, 2 + c.int(len(args)), name)
}

// Ticks every live, non-born actor with a healthy per-actor script, then each batch module once.
// Runs inside the world_update / world_fixed_update tick window.
script_update :: proc(world: ^World, dt: f32, phase: Script_Phase) {
	if world.scripts == nil do return
	host := world.scripts
	start := time.tick_now()
	defer host.frame_time += time.tick_diff(start, time.tick_now())
	for _, module in host.modules do if module.batch do clear(&module.ids)
	hooked := false // a per-actor hook ran: it may have destroyed or un-scripted collected batch actors
	for index := 0; index < len(world.slots); index += 1 {
		slot := &world.slots[index]
		if !slot.alive || slot.born do continue
		script := slot_component(slot, Script)
		if script == nil || script.faulted || script.module == nil do continue
		id := Actor_Id{u32(index), slot.generation}
		if script.module.batch {
			append(&script.module.ids, id)
			continue
		}
		hooked = true
		// A hook may destroy actors or spawn (growing world.slots): take nothing from slot after the call.
		switch phase {
		case .Tick:
			if script.module.tick != LUA_NOREF do script_invoke(world, id, script, script.module.tick, "tick", dt)
		case .Fixed_Tick:
			if script.module.fixed_tick != LUA_NOREF do script_invoke(world, id, script, script.module.fixed_tick, "fixed_tick", dt)
		}
	}
	// Collected before any batch call: a hook may spawn, and a spawn can load a module into host.modules.
	batches := make([dynamic]^Script_Module, context.temp_allocator)
	for _, module in host.modules do if module.batch do append(&batches, module)
	for module in batches {
		script_batch_tick(world, module, dt, phase, hooked)
		hooked = true // a batch hook may destroy actors of the modules still to run
	}
}

// One tick_all / fixed_tick_all call for the module's live actors, ids collected by script_update.
// hooked: re-check the ids first, since hooks ran after collection. An error faults every actor of the module until reload.
script_batch_tick :: proc(world: ^World, module: ^Script_Module, dt: f32, phase: Script_Phase, hooked: bool) {
	fn := module.tick_all
	what: cstring = "tick_all"
	if phase == .Fixed_Tick {
		fn = module.fixed_tick_all
		what = "fixed_tick_all"
	}
	if fn == LUA_NOREF do return
	if hooked {
		live := 0
		for id in module.ids {
			slot := &world.slots[id.index]
			if !slot.alive || slot.generation != id.generation do continue
			script := slot_component(slot, Script)
			if script == nil || script.faulted || script.module != module do continue
			module.ids[live] = id
			live += 1
		}
		resize(&module.ids, live)
	}
	if len(module.ids) == 0 do return
	host := world.scripts
	L := host.L
	top := luajit.gettop(L)
	defer luajit.settop(L, top)
	luajit.rawgeti(L, luajit.REGISTRYINDEX, host.handler) // top+1
	luajit.rawgeti(L, luajit.REGISTRYINDEX, fn)
	luajit.pushnumber(L, luajit.Number(uintptr(raw_data(module.ids))))
	luajit.pushnumber(L, luajit.Number(len(module.ids)))
	luajit.pushnumber(L, luajit.Number(dt))
	if luajit.pcall(L, 3, 0, top+1) == luajit.LUA_OK do return
	log.errorf("script %q: %s: %s", module.path, what, luajit.tostring(L, -1))
	for index := 0; index < len(world.slots); index += 1 {
		slot := &world.slots[index]
		if !slot.alive do continue
		if script := slot_component(slot, Script); script != nil && script.module == module do script.faulted = true
	}
}

// Vendored jit.v and the jit.vmdef it needs, embedded so the binary does not depend on package.path.
JIT_V_SRC :: #load("../../third_party/luajit/src/jit/v.lua", string)
JIT_VMDEF_SRC :: #load("../../third_party/luajit/src/jit/vmdef.lua", string)
// Args: v_src, vmdef_src, on. Preloads both modules once, then turns jit.v dumping on or off (stderr).
JIT_DEBUG_SRC :: "local v_src, vmdef_src, on = ...; if not package.preload['jit.v'] then package.preload['jit.vmdef'] = function() return assert(loadstring(vmdef_src, '=jit/vmdef.lua'))() end; package.preload['jit.v'] = function() return assert(loadstring(v_src, '=jit/v.lua'))() end end; local v = require('jit.v'); if on then v.on() else v.off() end"

// Turns the trace dump of jit.v on or off for this world's Lua state. CUBES_JIT_V=1 turns it on at host creation.
script_set_jit_debug :: proc(world: ^World, on: bool) {
	script_jit_debug_set(script_host_get(world), on)
}

script_jit_debug_set :: proc(host: ^Script_Host, on: bool) {
	L := host.L
	top := luajit.gettop(L)
	defer luajit.settop(L, top)
	luajit.rawgeti(L, luajit.REGISTRYINDEX, host.handler) // top+1
	if luajit.loadstring(L, JIT_DEBUG_SRC) != luajit.LUA_OK {
		log.errorf("script: jit debug: %s", luajit.tostring(L, -1))
		return
	}
	luajit.pushlstring(L, raw_data(JIT_V_SRC), c.size_t(len(JIT_V_SRC)))
	luajit.pushlstring(L, raw_data(JIT_VMDEF_SRC), c.size_t(len(JIT_VMDEF_SRC)))
	luajit.pushboolean(L, c.int(on))
	if luajit.pcall(L, 3, 0, top+1) != luajit.LUA_OK {
		log.errorf("script: jit debug: %s", luajit.tostring(L, -1))
	}
}

// Brings the live actors of a module up to date after it was (re)loaded: actors of a replaced module
// become healthy and run its reload hook; actors whose first load failed run create now.
script_reload_actors :: proc(world: ^World, module: ^Script_Module) {
	for index := 0; index < len(world.slots); index += 1 {
		slot := &world.slots[index]
		if !slot.alive do continue
		script := slot_component(slot, Script)
		if script == nil do continue
		// Hooks may destroy or spawn (growing world.slots): take nothing from slot after the call.
		id := Actor_Id{u32(index), slot.generation}
		if script.module == module {
			script.faulted = false
			if module.reload != LUA_NOREF do script_invoke(world, id, script, module.reload, "reload")
		} else if script.module == nil && script.path == module.path {
			script.faulted = false
			script_init(world, id, script)
		}
	}
}

// Swaps in a new version of a loaded module, in place. On failure the old module keeps running and
// mtime is still recorded, so the same broken file is not retried or logged again.
script_reload_module :: proc(world: ^World, module: ^Script_Module, mtime: time.Time) -> bool {
	host := world.scripts
	module.mtime = mtime
	table := script_file_load(host, module.path)
	if table == LUA_NOREF do return false
	script_module_unref(host, module)
	script_module_fill(host, module, table)
	script_reload_actors(world, module)
	log.infof("script reloaded: %s", module.path)
	return true
}

// Reloads every module whose file mtime changed (every module when force), and retries failed loads
// the same way. No-op without a host. Failures are logged once per file change.
script_reload_check :: proc(world: ^World, force := false) {
	if world.scripts == nil do return
	host := world.scripts
	// Collected first: a retry moves its entry from failed to modules.
	paths := make([dynamic]string, context.temp_allocator)
	for _, module in host.modules do append(&paths, module.path)
	for _, failure in host.failed do append(&paths, failure.path)
	swapped := false
	for path in paths {
		mtime, ok := script_mtime(path)
		if !ok do continue
		key := script_path_key(path)
		if module, loaded := host.modules[key]; loaded {
			if force || mtime != module.mtime {
				if script_reload_module(world, module, mtime) do swapped = true
			}
		} else if force || mtime != host.failed[key].mtime {
			// path may be freed by script_module_load on success: do not use it after the call.
			if module := script_module_load(host, path); module != nil do script_reload_actors(world, module)
		}
	}
	if swapped do script_jit_flush(host)
}

// Drops compiled traces: JIT code of replaced functions must not keep running.
script_jit_flush :: proc(host: ^Script_Host) {
	L := host.L
	top := luajit.gettop(L)
	defer luajit.settop(L, top)
	if luajit.loadstring(L, "jit.flush()") == luajit.LUA_OK do _ = luajit.pcall(L, 0, 0, 0)
}

// Called first in world_update: runs script_reload_check at most once per SCRIPT_RELOAD_INTERVAL.
script_host_poll_reload :: proc(world: ^World) {
	if world.scripts == nil do return
	host := world.scripts
	now := time.tick_now()
	if time.tick_diff(host.last_poll, now) < SCRIPT_RELOAD_INTERVAL do return
	host.last_poll = now
	script_reload_check(world)
}

// Runs the script heap's incremental GC for at most gc_budget (at least one step, at most
// SCRIPT_GC_MAX_STEPS), stopping early when a cycle completes. Counted in frame_time.
script_gc_step :: proc(world: ^World) {
	if world.scripts == nil do return
	host := world.scripts
	start := time.tick_now()
	for _ in 0 ..< SCRIPT_GC_MAX_STEPS {
		if luajit.gc(host.L, luajit.LUA_GCSTEP, 0) != 0 do break // cycle finished; the next frame starts a new one
		if time.tick_diff(start, time.tick_now()) >= host.gc_budget do break
	}
	host.frame_time += time.tick_diff(start, time.tick_now())
}

// Sets the per-frame GC budget of world's script host (creating the host if needed).
script_set_gc_budget :: proc(world: ^World, ms: f32) {
	script_host_get(world).gc_budget = time.Duration(f64(ms) * f64(time.Millisecond))
}

// Full collection of the script heap. The engine does not call it: a scene owns its world and
// its LuaJIT state, so a scene switch frees everything with the host.
script_collect :: proc(world: ^World) {
	if world.scripts != nil do _ = luajit.gc(world.scripts.L, luajit.LUA_GCCOLLECT, 0)
}
