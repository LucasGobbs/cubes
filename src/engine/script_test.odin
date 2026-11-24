package engine

import "core:fmt"
import "core:log"
import "core:os"
import "core:sync"
import "core:testing"
import "core:time"
import luajit "luajit"
import "input"
import mock "input/adapters/mock"

// Writes a Lua module to /tmp under a per-test name; the caller removes it.
@(private = "file")
script_test_write :: proc(name, src: string) -> string {
	path := fmt.tprintf("/tmp/cubes_script_test_%s.lua", name)
	err := os.write_entire_file(path, transmute([]byte)src)
	assert(err == nil, "script test: write failed")
	return path
}

// Reads a Lua global as a number; nil reads as 0.
@(private = "file")
script_test_number :: proc(world: ^World, name: cstring) -> f64 {
	L := world.scripts.L
	luajit.getglobal(L, name)
	defer luajit.pop(L)
	return luajit.tonumber(L, -1)
}

// Reads a Lua global as a string, cloned out of the Lua state.
@(private = "file")
script_test_string :: proc(world: ^World, name: cstring) -> string {
	L := world.scripts.L
	luajit.getglobal(L, name)
	defer luajit.pop(L)
	return fmt.tprint(luajit.tostring(L, -1))
}

// Odin-side probe: records how many Lua ticks had run when its tick fired.
@(private = "file")
Order_Probe :: struct {
	seen: f64,
}

@(private = "file")
order_probe_tick :: proc(world: ^World, id: Actor_Id, self: ^Order_Probe, dt: f32) {
	self.seen = script_test_number(world, "ticks")
}

// Odin-side destroyer: its tick removes one batch actor before Lua runs.
@(private = "file")
Batch_Killer :: struct {
	victim: Actor_Id,
}

@(private = "file")
batch_killer_tick :: proc(world: ^World, id: Actor_Id, self: ^Batch_Killer, dt: f32) {
	world_destroy_actor(world, self.victim)
}

@(test)
script_tick_counts_and_keeps_self :: proc(t: ^testing.T) {
	path := script_test_write("tick", `
local M = {}
function M.tick(self, a, dt)
	ticks = (ticks or 0) + 1
	last_dt = dt
	actor_index = a.index
	self.n = (self.n or 0) + 1
	self_n = self.n
end
return M
`)
	defer os.remove(path)
	world := world_create(nil)
	defer world_destroy(&world)

	id := spawn(&world, Script{path = path})
	for _ in 0 ..< 3 do world_update(&world, 0.5)

	testing.expect_value(t, script_test_number(&world, "ticks"), 3)
	testing.expect_value(t, script_test_number(&world, "last_dt"), 0.5)
	testing.expect_value(t, script_test_number(&world, "self_n"), 3)
	testing.expect_value(t, script_test_number(&world, "actor_index"), f64(id.index))
}

@(test)
script_fixed_tick_runs_only_from_fixed_update :: proc(t: ^testing.T) {
	path := script_test_write("fixed", `
local M = {}
function M.tick(self, a, dt) ticks = (ticks or 0) + 1 end
function M.fixed_tick(self, a, dt) fixed = (fixed or 0) + 1 end
return M
`)
	defer os.remove(path)
	world := world_create(nil)
	defer world_destroy(&world)

	spawn(&world, Script{path = path})
	for _ in 0 ..< 4 do world_fixed_update(&world, 1.0 / 60)

	testing.expect_value(t, script_test_number(&world, "fixed"), 4)
	testing.expect_value(t, script_test_number(&world, "ticks"), 0)

	world_update(&world, 1.0 / 60)
	testing.expect_value(t, script_test_number(&world, "fixed"), 4)
	testing.expect_value(t, script_test_number(&world, "ticks"), 1)
}

@(test)
script_tick_runs_after_odin_tick :: proc(t: ^testing.T) {
	path := script_test_write("order", `
local M = {}
function M.tick(self, a, dt) ticks = (ticks or 0) + 1 end
return M
`)
	defer os.remove(path)
	world := world_create(nil)
	defer world_destroy(&world)

	probe_type := register_type(&world, Order_Probe, nil, order_probe_tick, nil)
	_, probe := spawn_typed(&world, probe_type, Order_Probe{}, Script{path = path})

	// Odin tick sees the Lua tick count from before this frame, so Odin ran first.
	world_update(&world, 0.1)
	testing.expect_value(t, probe.seen, 0)
	testing.expect_value(t, script_test_number(&world, "ticks"), 1)

	world_update(&world, 0.1)
	testing.expect_value(t, probe.seen, 1)
	testing.expect_value(t, script_test_number(&world, "ticks"), 2)
}

@(test)
script_runtime_error_faults_only_that_actor :: proc(t: ^testing.T) {
	context.logger = log.nil_logger()
	bad_path := script_test_write("error_bad", `
local M = {}
function M.tick(self, a, dt)
	a_ticks = (a_ticks or 0) + 1
	error("boom")
end
return M
`)
	defer os.remove(bad_path)
	good_path := script_test_write("error_good", `
local M = {}
function M.tick(self, a, dt) b_ticks = (b_ticks or 0) + 1 end
return M
`)
	defer os.remove(good_path)
	world := world_create(nil)
	defer world_destroy(&world)

	bad := spawn(&world, Script{path = bad_path})
	good := spawn(&world, Script{path = good_path})
	for _ in 0 ..< 3 do world_update(&world, 0.1)

	testing.expect_value(t, script_test_number(&world, "a_ticks"), 1)
	testing.expect_value(t, script_test_number(&world, "b_ticks"), 3)
	testing.expect(t, actor_props(&world, bad, Script).faulted, "failing script is faulted")
	testing.expect(t, !actor_props(&world, good, Script).faulted, "healthy script keeps running")
}

@(test)
script_create_runs_on_spawn :: proc(t: ^testing.T) {
	path := script_test_write("create", `
local M = {}
function M.create(self, a) created = (created or 0) + 1 end
return M
`)
	defer os.remove(path)
	world := world_create(nil)
	defer world_destroy(&world)

	spawn(&world, Script{path = path})
	testing.expect_value(t, script_test_number(&world, "created"), 1)
}

@(test)
script_destroy_runs_on_destroy_actor :: proc(t: ^testing.T) {
	path := script_test_write("destroy_actor", `
local M = {}
function M.destroy(self, a) destroyed = (destroyed or 0) + 1 end
return M
`)
	defer os.remove(path)
	world := world_create(nil)
	defer world_destroy(&world)

	id := spawn(&world, Script{path = path})
	world_destroy_actor(&world, id)
	testing.expect_value(t, script_test_number(&world, "destroyed"), 1)
}

@(test)
script_destroy_runs_on_world_destroy :: proc(t: ^testing.T) {
	// The host is closed by world_destroy, so the Lua side reports through a marker file.
	marker := "/tmp/cubes_script_test_destroy_marker.txt"
	defer os.remove(marker)
	path := script_test_write("destroy_world", `
local M = {}
function M.destroy(self, a)
	local f = assert(io.open("/tmp/cubes_script_test_destroy_marker.txt", "w"))
	f:write("1")
	f:close()
end
return M
`)
	defer os.remove(path)
	world := world_create(nil)

	spawn(&world, Script{path = path})
	world_destroy(&world)

	data, err := os.read_entire_file(marker, context.temp_allocator)
	testing.expect(t, err == nil, "destroy wrote the marker file")
	testing.expect_value(t, string(data), "1")
}

@(test)
script_call_invokes_named_function :: proc(t: ^testing.T) {
	path := script_test_write("call", `
local M = {}
function M.on_hit(self, a, dmg)
	hit_dmg = dmg
	hit_index = a.index
end
return M
`)
	defer os.remove(path)
	world := world_create(nil)
	defer world_destroy(&world)

	id := spawn(&world, Script{path = path})
	testing.expect(t, script_call(&world, id, "on_hit", 10), "script_call returns true for present function")
	testing.expect_value(t, script_test_number(&world, "hit_dmg"), 10)
	testing.expect_value(t, script_test_number(&world, "hit_index"), f64(id.index))
	testing.expect(t, !script_call(&world, id, "missing"), "script_call returns false for missing function")
}

@(test)
script_missing_file_faults_without_crash :: proc(t: ^testing.T) {
	context.logger = log.nil_logger()
	world := world_create(nil)
	defer world_destroy(&world)

	id := spawn(&world, Script{path = "/tmp/cubes_script_test_does_not_exist.lua"})
	testing.expect(t, actor_props(&world, id, Script).faulted, "missing module faults the script")
	world_update(&world, 0.1)
	world_fixed_update(&world, 1.0 / 60)
	testing.expect(t, !script_call(&world, id, "on_hit", 1), "script_call on faulted script returns false")
}

@(test)
script_replace_runs_old_destroy_then_new_create :: proc(t: ^testing.T) {
	path_a := script_test_write("replace_a", `
local M = {}
trace = trace or ""
function M.create(self, a) trace = trace .. "Ac;" end
function M.destroy(self, a) trace = trace .. "Ad;" end
return M
`)
	defer os.remove(path_a)
	path_b := script_test_write("replace_b", `
local M = {}
trace = trace or ""
function M.create(self, a) trace = trace .. "Bc;" end
function M.destroy(self, a) trace = trace .. "Bd;" end
return M
`)
	defer os.remove(path_b)
	world := world_create(nil)
	defer world_destroy(&world)

	id := spawn(&world, Script{path = path_a})
	actor_add_props(&world, id, Script{path = path_b})
	testing.expect_value(t, script_test_string(&world, "trace"), "Ac;Ad;Bc;")
}

// The API thunks read package-level world/input pointers, and odin test runs tests in parallel.
@(private = "file")
script_api_lock: sync.Mutex

@(test)
script_api_transform_write_visible_to_odin :: proc(t: ^testing.T) {
	sync.guard(&script_api_lock)
	path := script_test_write("transform", `
local M = {}
function M.tick(self, a, dt)
  local tr = a:transform()
  tr.position.x = tr.position.x + dt
end
return M
`)
	defer os.remove(path)
	inputs := input.system_create(mock.create())
	defer input.system_destroy(&inputs)
	world := world_create(nil)
	defer world_destroy(&world)
	script_bind(&world, &inputs)

	id := spawn(&world, Script{path = path})
	for _ in 0 ..< 3 do world_update(&world, 0.5)
	testing.expect_value(t, actor_props(&world, id, Transform).position.x, f32(1.5))
}

@(test)
script_api_engine_layout_matches_odin :: proc(t: ^testing.T) {
	world := world_create(nil)
	defer world_destroy(&world)
	host := script_host_get(&world)
	testing.expect(t, host.ready)
	L := host.L
	testing.expect_value(t, luajit.loadstring(L, "_size = require('ffi').sizeof('Transform')"), luajit.LUA_OK)
	testing.expect_value(t, luajit.pcall(L, 0, 0, 0), luajit.LUA_OK)
	testing.expect_value(t, script_test_number(&world, "_size"), f64(size_of(Transform)))
}

@(test)
script_api_stale_handle_is_inert :: proc(t: ^testing.T) {
	sync.guard(&script_api_lock)
	owner := script_test_write("stale_owner", `
local M = {}
function M.create(self, a) stale = a end
return M
`)
	defer os.remove(owner)
	probe := script_test_write("stale_probe", `
local M = {}
function M.tick(self, a, dt)
  if stale == nil or probed then return end
  probed = 1
  stale_valid = stale:valid() and 1 or 0
  stale_transform_nil = stale:transform() == nil and 1 or 0
  stale:destroy()
end
return M
`)
	defer os.remove(probe)
	inputs := input.system_create(mock.create())
	defer input.system_destroy(&inputs)
	world := world_create(nil)
	defer world_destroy(&world)
	script_bind(&world, &inputs)

	dead := spawn(&world, Script{path = owner})
	world_destroy_actor(&world, dead)
	spawn(&world, Script{path = probe}) // reuses the slot with a new generation
	world_update(&world, 0.1)
	testing.expect_value(t, script_test_number(&world, "probed"), 1)
	testing.expect_value(t, script_test_number(&world, "stale_valid"), 0)
	testing.expect_value(t, script_test_number(&world, "stale_transform_nil"), 1)
}

@(test)
script_api_find_and_input :: proc(t: ^testing.T) {
	sync.guard(&script_api_lock)
	path := script_test_write("find_input", `
local engine = require("engine")
local M = {}
function M.tick(self, a, dt)
  local hero = engine.find("hero")
  found_index = hero and hero.index or -1
  missing = engine.find("nobody") == nil and 1 or 0
  down_now = engine.input.down("W") and 1 or 0
  pressed_now = engine.input.pressed("W") and 1 or 0
end
return M
`)
	defer os.remove(path)
	inputs := input.system_create(mock.create())
	defer input.system_destroy(&inputs)
	world := world_create(nil)
	defer world_destroy(&world)
	script_bind(&world, &inputs)

	_ = input.button(&inputs, "W", .W)
	input.key_set(&inputs, .W, true)
	input.update(&inputs)
	hero := spawn(&world, Name{value = "hero"})
	spawn(&world, Script{path = path})
	world_update(&world, 0.1)
	testing.expect_value(t, script_test_number(&world, "found_index"), f64(hero.index))
	testing.expect_value(t, script_test_number(&world, "missing"), 1)
	testing.expect_value(t, script_test_number(&world, "down_now"), 1)
	testing.expect_value(t, script_test_number(&world, "pressed_now"), 1)

	input.update(&inputs) // key still held: down stays, pressed clears
	world_update(&world, 0.1)
	testing.expect_value(t, script_test_number(&world, "down_now"), 1)
	testing.expect_value(t, script_test_number(&world, "pressed_now"), 0)
}

// Test-only Prop types. Test_Hp is exposed to Lua; Test_Other is registered but never exposed.
@(private = "file")
Test_Hp :: struct {
	hp, max_hp: f32,
}

@(private = "file")
Test_Other :: struct {
	v: f32,
}

@(test)
script_error_after_self_destroy_is_safe :: proc(t: ^testing.T) {
	sync.guard(&script_api_lock)
	context.logger = log.nil_logger()
	kill_path := script_test_write("self_kill", `
local M = {}
function M.tick(self, a, dt)
  a:destroy()
  error("boom")
end
function M.on_hit(self, a, dmg)
  a:destroy()
  error("boom")
end
return M
`)
	defer os.remove(kill_path)
	other_path := script_test_write("self_kill_other", `
local M = {}
function M.tick(self, a, dt) other_ticks = (other_ticks or 0) + 1 end
return M
`)
	defer os.remove(other_path)
	inputs := input.system_create(mock.create())
	defer input.system_destroy(&inputs)
	world := world_create(nil)
	defer world_destroy(&world)
	script_bind(&world, &inputs)

	doomed := spawn(&world, Script{path = kill_path})
	spawn(&world, Script{path = other_path})
	world_update(&world, 0.1)
	testing.expect(t, !world_valid(&world, doomed), "self-destroyed actor is gone after failing tick")
	testing.expect_value(t, script_test_number(&world, "other_ticks"), 1)
	doomed2 := spawn(&world, Script{path = kill_path})
	testing.expect(t, !script_call(&world, doomed2, "on_hit", 1), "failing call returns false")
	testing.expect(t, !world_valid(&world, doomed2), "call destroyed its own actor")
	world_update(&world, 0.1)
	testing.expect_value(t, script_test_number(&world, "other_ticks"), 2)
}

@(test)
script_expose_prop_reads_and_writes :: proc(t: ^testing.T) {
	sync.guard(&script_api_lock)
	path := script_test_write("prop_rw", `
local M = {}
function M.on_hit(self, a, dmg)
  local h = a:prop("Test_Hp")
  h.hp = h.hp - dmg
  hp_max_seen = h.max_hp
end
return M
`)
	defer os.remove(path)
	inputs := input.system_create(mock.create())
	defer input.system_destroy(&inputs)
	world := world_create(nil)
	defer world_destroy(&world)
	script_bind(&world, &inputs)
	register_props(&world, Test_Hp)
	testing.expect(t, script_expose(&world, Test_Hp, "Test_Hp", "typedef struct { float hp, max_hp; } Test_Hp;"), "Test_Hp exposes")

	id := spawn(&world, Script{path = path}, Test_Hp{hp = 30, max_hp = 40})
	testing.expect(t, script_call(&world, id, "on_hit", 10), "on_hit runs")
	testing.expect_value(t, actor_props(&world, id, Test_Hp).hp, 20)
	testing.expect_value(t, script_test_number(&world, "hp_max_seen"), 40)
}

@(test)
script_expose_prop_nil_when_absent_or_unexposed :: proc(t: ^testing.T) {
	sync.guard(&script_api_lock)
	context.logger = log.nil_logger()
	path := script_test_write("prop_nil", `
local M = {}
function M.create(self, a)
  if a:prop("Test_Hp") == nil then no_hp = (no_hp or 0) + 1 end
  if a:prop("Test_Other") == nil then no_other = (no_other or 0) + 1 end
end
return M
`)
	defer os.remove(path)
	inputs := input.system_create(mock.create())
	defer input.system_destroy(&inputs)
	world := world_create(nil)
	defer world_destroy(&world)
	script_bind(&world, &inputs)
	register_props(&world, Test_Hp)
	register_props(&world, Test_Other)
	testing.expect(t, script_expose(&world, Test_Hp, "Test_Hp", "typedef struct { float hp, max_hp; } Test_Hp;"), "Test_Hp exposes")

	spawn(&world, Script{path = path}) // no Test_Hp: absent
	spawn(&world, Script{path = path}, Test_Other{v = 1}) // present but unexposed
	testing.expect_value(t, script_test_number(&world, "no_hp"), 2)
	testing.expect_value(t, script_test_number(&world, "no_other"), 2)
}

@(test)
script_expose_rejects_layout_mismatch :: proc(t: ^testing.T) {
	sync.guard(&script_api_lock)
	context.logger = log.nil_logger()
	path := script_test_write("prop_bad_layout", `
local M = {}
function M.create(self, a) bad_hp_nil = (a:prop("Test_Hp") == nil) and 1 or 0 end
return M
`)
	defer os.remove(path)
	inputs := input.system_create(mock.create())
	defer input.system_destroy(&inputs)
	world := world_create(nil)
	defer world_destroy(&world)
	script_bind(&world, &inputs)
	register_props(&world, Test_Hp)
	// Missing max_hp: 4 bytes in LuaJIT, 8 in Odin.
	testing.expect(t, !script_expose(&world, Test_Hp, "Test_Hp", "typedef struct { float hp; } Test_Hp;"), "mismatched cdef is rejected")

	spawn(&world, Script{path = path}, Test_Hp{hp = 1, max_hp = 2})
	testing.expect_value(t, script_test_number(&world, "bad_hp_nil"), 1)
}

@(test)
script_expose_is_idempotent_per_type :: proc(t: ^testing.T) {
	sync.guard(&script_api_lock)
	context.logger = log.nil_logger()
	inputs := input.system_create(mock.create())
	defer input.system_destroy(&inputs)
	world := world_create(nil)
	defer world_destroy(&world)
	script_bind(&world, &inputs)
	cdef :: "typedef struct { float hp, max_hp; } Test_Hp;"
	testing.expect(t, script_expose(&world, Test_Hp, "Test_Hp", cdef), "first expose")
	testing.expect(t, script_expose(&world, Test_Hp, "Test_Hp", cdef), "same name and type again is accepted")
	testing.expect(t, !script_expose(&world, Test_Other, "Test_Hp", cdef), "same name with another type is rejected")
}

// Rewrites a module. The sleep keeps the new mtime distinct from the old one on coarse filesystems.
@(private = "file")
script_test_rewrite :: proc(path, src: string) {
	time.sleep(20 * time.Millisecond)
	err := os.write_entire_file(path, transmute([]byte)src)
	assert(err == nil, "script test: rewrite failed")
}

// Logger that counts error-level lines in the int behind data.
@(private = "file")
script_test_count_errors :: proc(data: rawptr, level: log.Level, text: string, options: log.Options, location := #caller_location) {
	if level < .Error do return
	counter := (^int)(data)
	counter^ += 1
}

@(test)
script_reload_swaps_module_keeps_actor_state :: proc(t: ^testing.T) {
	context.logger = log.nil_logger()
	path := script_test_write("reload_swap", `
local M = {}
function M.tick(self, a, dt)
	v = (v or 0) + 1
	self.n = (self.n or 0) + 1
	self_n = self.n
end
return M
`)
	defer os.remove(path)
	world := world_create(nil)
	defer world_destroy(&world)

	spawn(&world, Script{path = path})
	world_update(&world, 0.1)
	testing.expect_value(t, script_test_number(&world, "v"), 1)

	script_test_rewrite(path, `
local M = {}
function M.tick(self, a, dt)
	v = (v or 0) + 10
	self.n = (self.n or 0) + 1
	self_n = self.n
end
return M
`)
	script_reload_check(&world)
	world_update(&world, 0.1)
	testing.expect_value(t, script_test_number(&world, "v"), 11)
	testing.expect_value(t, script_test_number(&world, "self_n"), 2)
}

@(test)
script_reload_hook_runs_once_per_live_actor :: proc(t: ^testing.T) {
	context.logger = log.nil_logger()
	path := script_test_write("reload_hook", `
local M = {}
function M.tick(self, a, dt) end
return M
`)
	defer os.remove(path)
	world := world_create(nil)
	defer world_destroy(&world)

	spawn(&world, Script{path = path})
	spawn(&world, Script{path = path})
	script_test_rewrite(path, `
local M = {}
function M.tick(self, a, dt) end
function M.reload(self, a)
	reloads = (reloads or 0) + 1
end
return M
`)
	script_reload_check(&world)
	testing.expect_value(t, script_test_number(&world, "reloads"), 2)
	script_reload_check(&world) // mtime unchanged: nothing runs
	testing.expect_value(t, script_test_number(&world, "reloads"), 2)
}

@(test)
script_broken_reload_keeps_old_module_and_logs_once :: proc(t: ^testing.T) {
	context.logger = log.nil_logger()
	path := script_test_write("reload_broken", `
local M = {}
function M.tick(self, a, dt) v = (v or 0) + 1 end
return M
`)
	defer os.remove(path)
	world := world_create(nil)
	defer world_destroy(&world)

	id := spawn(&world, Script{path = path})
	world_update(&world, 0.1)
	testing.expect_value(t, script_test_number(&world, "v"), 1)

	errors := 0
	context.logger = log.Logger{procedure = script_test_count_errors, data = &errors, lowest_level = .Error}
	script_test_rewrite(path, `
local M = {}
function M.tick(self, a, dt) v = (v or 0) + 1 end
return M(
`)
	script_reload_check(&world)
	world_update(&world, 0.1)
	script_reload_check(&world) // same broken mtime: not logged again
	world_update(&world, 0.1)
	testing.expect_value(t, errors, 1)
	testing.expect_value(t, script_test_number(&world, "v"), 3)
	testing.expect(t, !actor_props(&world, id, Script).faulted, "old module keeps running after broken reload")
}

@(test)
script_fixed_reload_applies_after_broken_reload :: proc(t: ^testing.T) {
	context.logger = log.nil_logger()
	path := script_test_write("reload_fix", `
local M = {}
function M.tick(self, a, dt) v = (v or 0) + 1 end
return M
`)
	defer os.remove(path)
	world := world_create(nil)
	defer world_destroy(&world)

	spawn(&world, Script{path = path})
	world_update(&world, 0.1)
	script_test_rewrite(path, "local M = {}\nreturn M(\n")
	script_reload_check(&world)
	script_test_rewrite(path, `
local M = {}
function M.tick(self, a, dt) v = (v or 0) + 100 end
return M
`)
	script_reload_check(&world)
	world_update(&world, 0.1)
	testing.expect_value(t, script_test_number(&world, "v"), 101)
}

@(test)
script_faulted_actor_recovers_after_fixed_reload :: proc(t: ^testing.T) {
	context.logger = log.nil_logger()
	path := script_test_write("reload_recover", `
local M = {}
function M.tick(self, a, dt) error("boom") end
return M
`)
	defer os.remove(path)
	world := world_create(nil)
	defer world_destroy(&world)

	id := spawn(&world, Script{path = path})
	world_update(&world, 0.1)
	testing.expect(t, actor_props(&world, id, Script).faulted, "runtime error faults the actor")

	script_test_rewrite(path, `
local M = {}
function M.tick(self, a, dt)
	ticks = (ticks or 0) + 1
end
return M
`)
	script_reload_check(&world)
	world_update(&world, 0.1)
	testing.expect_value(t, script_test_number(&world, "ticks"), 1)
	testing.expect(t, !actor_props(&world, id, Script).faulted, "reload clears the fault")
}

@(test)
script_spawn_with_broken_module_recovers_on_fixed_reload :: proc(t: ^testing.T) {
	context.logger = log.nil_logger()
	path := script_test_write("reload_spawn_broken", "local M = {}\nreturn M(\n")
	defer os.remove(path)
	world := world_create(nil)
	defer world_destroy(&world)

	id := spawn(&world, Script{path = path})
	testing.expect(t, actor_props(&world, id, Script).faulted, "broken module faults at spawn")
	testing.expect(t, actor_props(&world, id, Script).module == nil, "no module for a broken spawn")

	script_test_rewrite(path, `
local M = {}
function M.create(self, a) created = (created or 0) + 1 end
function M.tick(self, a, dt)
	ticks = (ticks or 0) + 1
end
return M
`)
	script_reload_check(&world)
	testing.expect_value(t, script_test_number(&world, "created"), 1)
	world_update(&world, 0.1)
	testing.expect_value(t, script_test_number(&world, "ticks"), 1)
	testing.expect(t, !actor_props(&world, id, Script).faulted, "actor healthy after module recovers")
}

@(test)
script_unbind_on_world_destroy_is_safe :: proc(t: ^testing.T) {
	sync.guard(&script_api_lock)
	inputs := input.system_create(mock.create())
	defer input.system_destroy(&inputs)
	world := world_create(nil)
	script_bind(&world, &inputs)
	world_destroy(&world)
	script_reload_all()
	testing.expect(t, !script_input_ready(), "inputs unbound with the world")
	_, ok := script_take_frame_ms()
	testing.expect(t, !ok, "no script host bound after world_destroy")
}

@(test)
script_take_frame_ms_resets_after_read :: proc(t: ^testing.T) {
	sync.guard(&script_api_lock)
	inputs := input.system_create(mock.create())
	defer input.system_destroy(&inputs)
	world := world_create(nil)
	defer world_destroy(&world)
	script_bind(&world, &inputs)
	world_update(&world, 0.1)
	_ = script_host_get(&world) // a script host exists only once something asks for one
	_, ok := script_take_frame_ms()
	testing.expect(t, ok, "bound world with a script host reports frame time")
	ms, _ := script_take_frame_ms()
	testing.expect_value(t, ms, 0)
}

@(test)
script_gc_step_reclaims_garbage_under_budget :: proc(t: ^testing.T) {
	world := world_create(nil)
	defer world_destroy(&world)
	host := script_host_get(&world)
	testing.expect_value(t, luajit.gc(host.L, luajit.LUA_GCISRUNNING, 0), 0)
	script_set_gc_budget(&world, 1000)
	if luajit.loadstring(host.L, "local t = {} for i = 1, 300000 do t[i % 100 + 1] = {i} end") == luajit.LUA_OK do _ = luajit.pcall(host.L, 0, 0, 0)
	peak := luajit.gc(host.L, luajit.LUA_GCCOUNT, 0)
	for _ in 0 ..< 1000 do script_gc_step(&world)
	testing.expect(t, luajit.gc(host.L, luajit.LUA_GCCOUNT, 0) < peak, "gc steps reclaim garbage with automatic gc stopped")
	script_set_gc_budget(&world, 0)
	script_gc_step(&world) // zero budget still does one step and returns
}

@(test)
script_batch_tick_all_once_per_update :: proc(t: ^testing.T) {
	sync.guard(&script_api_lock)
	inputs := input.system_create(mock.create())
	defer input.system_destroy(&inputs)
	world := world_create(nil)
	defer world_destroy(&world)
	script_bind(&world, &inputs)
	path := script_test_write("batch", `
local M = {}
M.batch = true
function M.tick_all(ids, count, dt)
	batch_calls = (batch_calls or 0) + 1
	batch_count = count
	for i = 0, count - 1 do
		local t = ids[i]:transform()
		t.position.x = t.position.x + dt
	end
end
function M.tick(self, a, dt)
	per_actor_ticks = (per_actor_ticks or 0) + 1
end
return M
`)
	defer os.remove(path)
	ids: [5]Actor_Id
	for &id in ids do id = spawn(&world, Transform{}, Script{path = path})
	world_update(&world, 0.5)
	world_update(&world, 0.5)
	testing.expect_value(t, script_test_number(&world, "batch_calls"), 2)
	testing.expect_value(t, script_test_number(&world, "batch_count"), 5)
	testing.expect_value(t, script_test_number(&world, "per_actor_ticks"), 0)
	for id in ids do testing.expect_value(t, slot_component(&world.slots[id.index], Transform).position.x, 1.0)
	world_destroy_actor(&world, ids[0])
	world_update(&world, 0.5)
	testing.expect_value(t, script_test_number(&world, "batch_count"), 4)
}

@(test)
script_batch_error_faults_module_only :: proc(t: ^testing.T) {
	context.logger = log.nil_logger()
	sync.guard(&script_api_lock)
	inputs := input.system_create(mock.create())
	defer input.system_destroy(&inputs)
	world := world_create(nil)
	defer world_destroy(&world)
	script_bind(&world, &inputs)
	bad := script_test_write("batch_bad", `
local M = {}
M.batch = true
function M.tick_all(ids, count, dt)
	bad_calls = (bad_calls or 0) + 1
	error("boom")
end
return M
`)
	good := script_test_write("batch_good", `
local M = {}
function M.tick(self, a, dt)
	good_ticks = (good_ticks or 0) + 1
end
return M
`)
	defer os.remove(bad)
	defer os.remove(good)
	bad_ids: [2]Actor_Id
	for &id in bad_ids do id = spawn(&world, Transform{}, Script{path = bad})
	good_id := spawn(&world, Transform{}, Script{path = good})
	world_update(&world, 0.1)
	world_update(&world, 0.1)
	testing.expect_value(t, script_test_number(&world, "bad_calls"), 1)
	testing.expect_value(t, script_test_number(&world, "good_ticks"), 2)
	for id in bad_ids do testing.expect(t, slot_component(&world.slots[id.index], Script).faulted, "batch error faults every actor of the module")
	testing.expect(t, !slot_component(&world.slots[good_id.index], Script).faulted, "healthy module keeps ticking")
}

@(test)
script_batch_odin_tick_destroy_skips_stale_id :: proc(t: ^testing.T) {
	context.logger = log.nil_logger()
	sync.guard(&script_api_lock)
	inputs := input.system_create(mock.create())
	defer input.system_destroy(&inputs)
	world := world_create(nil)
	defer world_destroy(&world)
	script_bind(&world, &inputs)
	path := script_test_write("batch_odin_destroy", `
local M = {}
M.batch = true
function M.tick_all(ids, count, dt)
	batch_calls = (batch_calls or 0) + 1
	batch_count = count
	for i = 0, count - 1 do
		if not ids[i]:valid() then stale = (stale or 0) + 1 end
	end
end
return M
`)
	defer os.remove(path)
	ids: [5]Actor_Id
	for &id in ids do id = spawn(&world, Transform{}, Script{path = path})
	victim_type := register_type(&world, Batch_Killer, nil, batch_killer_tick, nil)
	_, _ = spawn_typed(&world, victim_type, Batch_Killer{victim = ids[2]})
	world_update(&world, 0.1)
	testing.expect(t, !world_valid(&world, ids[2]), "odin tick destroyed the victim before the batch")
	testing.expect_value(t, script_test_number(&world, "batch_calls"), 1)
	testing.expect_value(t, script_test_number(&world, "batch_count"), 4)
	testing.expect_value(t, script_test_number(&world, "stale"), 0)
}

@(test)
script_batch_tick_all_destroy_next_frame_count :: proc(t: ^testing.T) {
	context.logger = log.nil_logger()
	sync.guard(&script_api_lock)
	inputs := input.system_create(mock.create())
	defer input.system_destroy(&inputs)
	world := world_create(nil)
	defer world_destroy(&world)
	script_bind(&world, &inputs)
	path := script_test_write("batch_self_destroy", `
local M = {}
M.batch = true
function M.tick_all(ids, count, dt)
	batch_calls = (batch_calls or 0) + 1
	batch_count = count
	if batch_calls == 1 then ids[0]:destroy() end
	local live = 0
	for i = 0, count - 1 do
		if ids[i]:valid() then live = live + 1 end
	end
	live_seen = live
end
return M
`)
	defer os.remove(path)
	ids: [5]Actor_Id
	for &id in ids do id = spawn(&world, Transform{}, Script{path = path})
	world_update(&world, 0.1)
	testing.expect_value(t, script_test_number(&world, "batch_count"), 5)
	testing.expect_value(t, script_test_number(&world, "live_seen"), 4)
	world_update(&world, 0.1)
	testing.expect_value(t, script_test_number(&world, "batch_calls"), 2)
	testing.expect_value(t, script_test_number(&world, "batch_count"), 4)
	testing.expect_value(t, script_test_number(&world, "live_seen"), 4)
}

@(test)
script_batch_lua_hook_destroys_collected_actor :: proc(t: ^testing.T) {
	context.logger = log.nil_logger()
	sync.guard(&script_api_lock)
	inputs := input.system_create(mock.create())
	defer input.system_destroy(&inputs)
	world := world_create(nil)
	defer world_destroy(&world)
	script_bind(&world, &inputs)
	batch := script_test_write("batch_hook_victim", `
local ffi = require("ffi")
local M = {}
M.batch = true
function M.tick_all(ids, count, dt)
	batch_calls = (batch_calls or 0) + 1
	batch_count = count
	for i = 0, count - 1 do
		if not ids[i]:valid() then stale = (stale or 0) + 1 end
	end
	if victim == nil then victim = ffi.new("Actor", ids[2]) end
end
return M
`)
	killer := script_test_write("batch_hook_killer", `
local M = {}
function M.tick(self, a, dt)
	if victim ~= nil and not killed then
		killed = true
		victim:destroy()
	end
end
return M
`)
	defer os.remove(batch)
	defer os.remove(killer)
	ids: [5]Actor_Id
	for &id in ids do id = spawn(&world, Transform{}, Script{path = batch})
	spawn(&world, Transform{}, Script{path = killer}) // ticks after the batch actors are collected
	world_update(&world, 0.1)
	testing.expect_value(t, script_test_number(&world, "batch_count"), 5)
	world_update(&world, 0.1)
	testing.expect(t, !world_valid(&world, ids[2]), "per-actor Lua hook destroyed the collected victim")
	testing.expect_value(t, script_test_number(&world, "batch_calls"), 2)
	testing.expect_value(t, script_test_number(&world, "batch_count"), 4)
	testing.expect_value(t, script_test_number(&world, "stale"), 0)
}

@(test)
script_set_jit_debug_loads_jit_v :: proc(t: ^testing.T) {
	world := world_create(nil)
	defer world_destroy(&world)
	script_set_jit_debug(&world, true)
	script_set_jit_debug(&world, false)
	L := script_host_get(&world).L
	luajit.getglobal(L, "package")
	luajit.getfield(L, -1, "loaded")
	luajit.getfield(L, -1, "jit.v")
	testing.expect_value(t, luajit.type(L, -1), LUA_TTABLE)
	luajit.settop(L, 0)
}

@(test)
script_path_key_folds_backslash_separators :: proc(t: ^testing.T) {
	testing.expect_value(t, script_path_key(`a\b.lua`), "a/b.lua")
	testing.expect_value(t, script_path_key(`a\b.lua`), script_path_key(`a/b.lua`))
}
