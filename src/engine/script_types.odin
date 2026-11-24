package engine

import "core:c"
import "core:time"

// Lua behaviour for an actor. path is borrowed: the string must outlive the actor.
// Fields after path belong to the host: spawn leaves them zero and the added hook fills them.
Script :: struct {
	path:      string,
	self_ref:  c.int, // registry ref of the per-actor Lua table; 0 = none
	actor_ref: c.int, // registry ref of the Actor cdata passed to hooks; 0 = none
	module:    ^Script_Module, // nil when the module failed to load; heap-stable across map growth
	faulted:   bool, // a runtime error stopped this actor's script; hooks are skipped
}

// One loaded module: its source path and the registry refs of its hooks. A function ref is
// LUA_NOREF when the module lacks it. Hot reload swaps the refs in place, so Script.module stays valid.
Script_Module :: struct {
	path:       string, // owned copy, as given; Script_Host.modules is keyed by script_path_key(path)
	mtime:      time.Time, // source mtime of the version in use, or of the last failed attempt
	table:      c.int,
	create:     c.int,
	tick:       c.int,
	fixed_tick: c.int,
	destroy:    c.int,
	reload:     c.int,
	batch:      bool, // M.batch = true: per-actor tick/fixed_tick are skipped; *_all get the whole batch
	tick_all:   c.int, // batch hook (ids, count, dt), wrapped by engine.lua's _batch; LUA_NOREF when absent
	fixed_tick_all: c.int,
}

Script_Phase :: enum {
	Tick,
	Fixed_Tick,
}

script_added :: proc(world: ^World, id: Actor_Id, self: ^Script) {
	script_init(world, id, self)
}

script_removed :: proc(world: ^World, id: Actor_Id, self: ^Script) {
	script_release(world, id, self)
}
