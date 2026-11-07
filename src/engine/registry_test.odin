package engine

import "core:testing"

// Entity state for the registry tests. Procs record into the state, so the
// assertions see exactly what the world called.
Counter :: struct {
	ticks: int,
}

Killer :: struct {
	target: Entity_Id,
}

Spawner :: struct {
	counter: Entity_Type,
	victim:  Entity_Id,
	done:    bool,
}

// Package-level so the procs can report without a testing handle.
@(private = "file")
destroy_calls: int
@(private = "file")
destroy_saw_valid: bool
@(private = "file")
counter_ticks: int

counter_tick :: proc(world: ^World, id: Entity_Id, self: ^Counter, dt: f32) {
	self.ticks += 1
	counter_ticks += 1
}

counter_destroy :: proc(world: ^World, id: Entity_Id, self: ^Counter) {
	destroy_calls += 1
	destroy_saw_valid = world_valid(world, id)
}

killer_tick :: proc(world: ^World, id: Entity_Id, self: ^Killer, dt: f32) {
	world_destroy_entity(world, self.target)
}

// Destroys the victim, then spawns into the victim's freed index.
spawner_tick :: proc(world: ^World, id: Entity_Id, self: ^Spawner, dt: f32) {
	if self.done do return
	self.done = true
	world_destroy_entity(world, self.victim)
	entity_spawn(world, self.counter, Counter{})
}

@(test)
tick_runs_once_per_update_per_live_entity :: proc(t: ^testing.T) {
	world := World{}
	defer world_destroy(&world)
	counter := entity_register(&world, Counter, nil, counter_tick, nil)

	_, a := entity_spawn(&world, counter, Counter{})
	_, b := entity_spawn(&world, counter, Counter{})
	for _ in 0 ..< 3 do world_update(&world, 0.1)

	testing.expect_value(t, a.ticks, 3)
	testing.expect_value(t, b.ticks, 3)
}

@(test)
destroy_runs_on_destroy_entity_and_world_destroy :: proc(t: ^testing.T) {
	destroy_calls = 0
	destroy_saw_valid = false
	world := World{}
	counter := entity_register(&world, Counter, nil, nil, counter_destroy)

	id, _ := entity_spawn(&world, counter, Counter{})
	world_destroy_entity(&world, id)
	testing.expect_value(t, destroy_calls, 1)
	testing.expect(t, destroy_saw_valid)
	world_destroy_entity(&world, id) // stale id: no second call
	testing.expect_value(t, destroy_calls, 1)

	entity_spawn(&world, counter, Counter{})
	entity_spawn(&world, counter, Counter{})
	world_destroy(&world)
	testing.expect_value(t, destroy_calls, 3)
}

@(test)
entity_destroyed_during_tick_is_not_ticked_after :: proc(t: ^testing.T) {
	counter_ticks = 0
	world := World{}
	defer world_destroy(&world)
	counter := entity_register(&world, Counter, nil, counter_tick, nil)
	killer := entity_register(&world, Killer, nil, killer_tick, nil)

	// Killer first: its slot ticks before the victim's, so the victim is skipped.
	_, killer_state := entity_spawn(&world, killer, Killer{})
	victim, _ := entity_spawn(&world, counter, Counter{})
	killer_state.target = victim
	world_update(&world, 0.1)

	testing.expect(t, !world_valid(&world, victim))
	testing.expect_value(t, counter_ticks, 0)
}

@(test)
spawn_during_tick_ticks_next_update :: proc(t: ^testing.T) {
	world := World{}
	defer world_destroy(&world)
	counter := entity_register(&world, Counter, nil, counter_tick, nil)
	spawner := entity_register(&world, Spawner, nil, spawner_tick, nil)

	// Spawner first, victim above it: the spawned entity reuses the victim's index,
	// which the update loop still reaches, so it must wait for the next update.
	_, spawner_state := entity_spawn(&world, spawner, Spawner{counter = counter})
	victim, _ := entity_spawn(&world, counter, Counter{})
	spawner_state.victim = victim

	world_update(&world, 0.1)
	fresh, state := world_find_state(&world, counter, Counter)
	testing.expect(t, state != nil)
	if state == nil do return
	testing.expect_value(t, fresh.index, victim.index)
	testing.expect_value(t, state.ticks, 0)

	world_update(&world, 0.1)
	testing.expect_value(t, state.ticks, 1)
}

@(test)
find_state_returns_first_live_of_type :: proc(t: ^testing.T) {
	world := World{}
	defer world_destroy(&world)
	counter := entity_register(&world, Counter, nil, nil, nil)
	other := entity_register(&world, Killer, nil, nil, nil)

	first, _ := entity_spawn(&world, counter, Counter{})
	entity_spawn(&world, other, Killer{})
	second, _ := entity_spawn(&world, counter, Counter{})
	testing.expect_value(t, world_count(&world, counter), 2)

	found, state := world_find_state(&world, counter, Counter)
	testing.expect_value(t, found, first)
	testing.expect(t, state != nil)
	testing.expect(t, world_get_state(&world, first, Counter) == state)

	world_destroy_entity(&world, first)
	found, _ = world_find_state(&world, counter, Counter)
	testing.expect_value(t, found, second)
	testing.expect_value(t, world_count(&world, counter), 1)
}
