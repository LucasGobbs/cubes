package engine

import "core:testing"

// Actor state for the lifecycle tests. Procs record into the state, so the
// assertions see exactly what the world called.
Counter :: struct {
	using actor: Actor,
	ticks:       int,
}

Killer :: struct {
	using actor: Actor,
	target:      Actor_Id,
}

Spawner :: struct {
	using actor: Actor,
	victim:      Actor_Id,
	done:        bool,
}

// Package-level so the procs can report without a testing handle.
@(private = "file")
destroy_calls: int
@(private = "file")
destroy_saw_valid: bool
@(private = "file")
counter_ticks: int

counter_tick :: proc(self: ^Counter, dt: f32) {
	self.ticks += 1
	counter_ticks += 1
}

counter_destroy :: proc(self: ^Counter) {
	destroy_calls += 1
	destroy_saw_valid = world_valid(self.world, self.id)
}

killer_tick :: proc(self: ^Killer, dt: f32) {
	world_destroy_actor(self.world, self.target)
}

// Destroys the victim, then spawns into the victim's freed index.
spawner_tick :: proc(self: ^Spawner, dt: f32) {
	if self.done do return
	self.done = true
	world_destroy_actor(self.world, self.victim)
	world_add_actor(self.world, Counter{actor = actor_hooks(Counter, tick = counter_tick)})
}

@(test)
tick_runs_once_per_update_per_live_actor :: proc(t: ^testing.T) {
	world := world_create(nil)
	defer world_destroy(&world)

	a := world_add_actor(&world, Counter{actor = actor_hooks(Counter, tick = counter_tick)})
	b := world_add_actor(&world, Counter{actor = actor_hooks(Counter, tick = counter_tick)})
	for _ in 0 ..< 3 do world_update(&world, 0.1)

	testing.expect_value(t, a.ticks, 3)
	testing.expect_value(t, b.ticks, 3)
}

@(test)
destroy_runs_on_destroy_actor_and_world_destroy :: proc(t: ^testing.T) {
	destroy_calls = 0
	destroy_saw_valid = false
	world := world_create(nil)

	first := world_add_actor(&world, Counter{actor = actor_hooks(Counter, destroy = counter_destroy)})
	first_id := first.id
	world_destroy_actor(&world, first_id)
	testing.expect_value(t, destroy_calls, 1)
	testing.expect(t, destroy_saw_valid)

	world_add_actor(&world, Counter{actor = actor_hooks(Counter, destroy = counter_destroy)})
	world_add_actor(&world, Counter{actor = actor_hooks(Counter, destroy = counter_destroy)})
	world_destroy(&world)
	testing.expect_value(t, destroy_calls, 3)
}

@(test)
actor_destroyed_during_tick_is_not_ticked_after :: proc(t: ^testing.T) {
	counter_ticks = 0
	world := world_create(nil)
	defer world_destroy(&world)

	// Killer first: its slot ticks before the victim's, so the victim is skipped.
	killer := world_add_actor(&world, Killer{actor = actor_hooks(Killer, tick = killer_tick)})
	victim := world_add_actor(&world, Counter{actor = actor_hooks(Counter, tick = counter_tick)})
	victim_id := victim.id
	killer.target = victim_id
	world_update(&world, 0.1)

	testing.expect(t, !world_valid(&world, victim_id))
	testing.expect_value(t, counter_ticks, 0)
}

@(test)
spawn_during_tick_ticks_next_update :: proc(t: ^testing.T) {
	world := world_create(nil)
	defer world_destroy(&world)

	// Spawner first, victim above it: the spawned actor reuses the victim's index,
	// which the update loop still reaches, so it must wait for the next update.
	spawner := world_add_actor(&world, Spawner{actor = actor_hooks(Spawner, tick = spawner_tick)})
	victim := world_add_actor(&world, Counter{actor = actor_hooks(Counter, tick = counter_tick)})
	victim_id := victim.id
	spawner.victim = victim_id

	world_update(&world, 0.1)
	fresh := world_find(&world, Counter)
	testing.expect(t, fresh != nil)
	if fresh == nil do return
	testing.expect_value(t, fresh.id.index, victim_id.index)
	testing.expect_value(t, fresh.ticks, 0)

	world_update(&world, 0.1)
	testing.expect_value(t, fresh.ticks, 1)
}

@(test)
find_returns_first_live_of_type :: proc(t: ^testing.T) {
	world := world_create(nil)
	defer world_destroy(&world)

	first := world_add_actor(&world, Counter{})
	first_id := first.id
	world_add_actor(&world, Killer{})
	second := world_add_actor(&world, Counter{})
	testing.expect_value(t, world_count(&world, Counter), 2)

	testing.expect(t, world_find(&world, Counter) == first)
	testing.expect(t, world_get(&world, first_id, Counter) == first)

	world_destroy_actor(&world, first_id)
	testing.expect(t, world_find(&world, Counter) == second)
	testing.expect_value(t, world_count(&world, Counter), 1)
}
