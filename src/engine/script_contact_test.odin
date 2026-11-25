package engine

import "core:fmt"
import "core:log"
import "core:os"
import "core:sync"
import "core:testing"
import luajit "luajit"

Contact_Probe :: struct {
	using actor: Actor,
	transform:   Transform,
	collider:    Collider,
	hits:        int,
	other:       Actor_Id,
	kill:        bool, // destroy the other actor from inside the hook
}

contact_probe_contact :: proc(self: ^Contact_Probe, other: Actor_Id) {
	self.hits += 1
	self.other = other
	if self.kill do world_destroy_actor(self.world, other)
}

@(private = "file")
contact_test_write :: proc(name, src: string) -> string {
	path := fmt.tprintf("/tmp/cubes_script_test_contact_%s.lua", name)
	err := os.write_entire_file(path, transmute([]byte)src)
	assert(err == nil, "contact test: write failed")
	return path
}

@(private = "file")
contact_test_number :: proc(world: ^World, name: cstring) -> f64 {
	L := world.scripts.L
	luajit.getglobal(L, name)
	defer luajit.pop(L)
	return luajit.tonumber(L, -1)
}

@(test)
contact_hook_fires_once_per_side :: proc(t: ^testing.T) {
	// No Device: physics runs without rendering.
	world := world_create(nil)
	defer world_destroy(&world)
	ground := world_add_actor(&world, Contact_Probe{
		actor     = actor_hooks(Contact_Probe, contact = contact_probe_contact),
		transform = Transform{position = {0, -0.5, 0}},
		collider  = Collider{shape = Box{{10, 0.5, 10}}, body = .Static},
	})
	ball := world_add_actor(&world, Contact_Probe{
		actor     = actor_hooks(Contact_Probe, contact = contact_probe_contact),
		transform = Transform{position = {0, 3, 0}},
		collider  = Collider{shape = Sphere{0.5}, body = .Dynamic},
	})
	ground_id, ball_id := ground.id, ball.id
	for _ in 0 ..< 120 do world_update(&world, 1.0 / 60.0)

	testing.expect_value(t, ball.hits, 1)
	testing.expect(t, ball.other == ground_id, "ball contact names the ground")
	testing.expect_value(t, ground.hits, 1)
	testing.expect(t, ground.other == ball_id, "ground contact names the ball")
}

@(test)
contact_hook_destroying_other_is_safe :: proc(t: ^testing.T) {
	world := world_create(nil)
	defer world_destroy(&world)
	ground := world_add_actor(&world, Contact_Probe{
		actor     = actor_hooks(Contact_Probe, contact = contact_probe_contact),
		transform = Transform{position = {0, -0.5, 0}},
		collider  = Collider{shape = Box{{10, 0.5, 10}}, body = .Static},
	})
	ball := world_add_actor(&world, Contact_Probe{
		actor     = actor_hooks(Contact_Probe, contact = contact_probe_contact),
		kill      = true,
		transform = Transform{position = {0, 3, 0}},
		collider  = Collider{shape = Sphere{0.5}, body = .Dynamic},
	})
	ground_id, ball_id := ground.id, ball.id
	for _ in 0 ..< 120 do world_update(&world, 1.0 / 60.0)

	testing.expect(t, world_valid(&world, ball_id), "killer survives its own hook")
	testing.expect_value(t, ball.hits, 1)
	testing.expect(t, !world_valid(&world, ground_id), "hook destroyed the other actor")
}

@(test)
contact_lua_on_contact_runs_once :: proc(t: ^testing.T) {
	sync.guard(&script_api_lock)
	path := contact_test_write("hit", `
local M = {}
function M.on_contact(self, a, other) hits = (hits or 0) + 1 end
return M
`)
	defer os.remove(path)
	world := world_create(nil)
	defer world_destroy(&world)

	spawn(&world, Transform{position = {0, -0.5, 0}}, Collider{shape = Box{{10, 0.5, 10}}, body = .Static})
	ball := spawn(&world, Script{path = path}, Transform{position = {0, 3, 0}}, Collider{shape = Sphere{0.5}, body = .Dynamic})
	for _ in 0 ..< 120 do world_update(&world, 1.0 / 60.0)

	testing.expect_value(t, contact_test_number(&world, "hits"), 1)
	testing.expect(t, !actor_props(&world, ball, Script).faulted, "healthy on_contact does not fault")
}

@(test)
contact_lua_error_faults_only_that_actor :: proc(t: ^testing.T) {
	sync.guard(&script_api_lock)
	context.logger = log.nil_logger()
	path := contact_test_write("boom", `
local M = {}
function M.on_contact(self, a, other) error("boom") end
return M
`)
	defer os.remove(path)
	world := world_create(nil)
	defer world_destroy(&world)

	ground := spawn(&world, Transform{position = {0, -0.5, 0}}, Collider{shape = Box{{10, 0.5, 10}}, body = .Static})
	ball := spawn(&world, Script{path = path}, Transform{position = {0, 3, 0}}, Collider{shape = Sphere{0.5}, body = .Dynamic})
	for _ in 0 ..< 120 do world_update(&world, 1.0 / 60.0)

	testing.expect(t, actor_props(&world, ball, Script).faulted, "on_contact error faults the actor")
	testing.expect(t, world_valid(&world, ground), "ground survives")
}
