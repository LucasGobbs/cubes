package engine

import "core:math/linalg"
import "core:testing"

Probe_Box :: struct {
	hp: int,
}

probe_box_live: int
probe_box_added_count: int
probe_box_removed_count: int

probe_box_added :: proc(world: ^World, id: Actor_Id, self: ^Probe_Box) {
	probe_box_live += 1
	probe_box_added_count += 1
}

probe_box_removed :: proc(world: ^World, id: Actor_Id, self: ^Probe_Box) {
	probe_box_live -= 1
	probe_box_removed_count += 1
}

Probe_Actor :: struct {
	using actor:     Actor,
	using transform: Transform,
	box:             Probe_Box,
	hp:              int, // unregistered: not a Prop, ignored
}

Probe_Ticker :: struct {
	using actor: Actor,
	ticks:       int,
	fixed_ticks: int,
	dt:          f32,
	seen:        ^Probe_Ticker,
}

probe_tick :: proc(self: ^Probe_Ticker, dt: f32) {
	self.ticks += 1
	self.dt = dt
	self.seen = self
}

probe_fixed_tick :: proc(self: ^Probe_Ticker, dt: f32) {
	self.fixed_ticks += 1
}

Probe_Dying :: struct {
	using actor: Actor,
	box:         Probe_Box,
}

probe_dying_count: int
probe_dying_hp: int

probe_dying_destroy :: proc(self: ^Probe_Dying) {
	probe_dying_count += 1
	probe_dying_hp = self.box.hp // Props still readable inside the destroy hook
}

Probe_Bad :: struct {
	hp:          int,
	using actor: Actor, // not first: rejected
}

@(test)
world_add_actor_embeds_props :: proc(t: ^testing.T) {
	probe_box_live = 0
	world := world_create(nil)
	defer world_destroy(&world)
	register_props(&world, Probe_Box, probe_box_added, probe_box_removed)

	a := world_add_actor(&world, Probe_Actor{transform = Transform{position = {1, 2, 3}}, box = Probe_Box{hp = 4}})
	testing.expect(t, world_valid(&world, a.id))
	testing.expect(t, world_get(&world, a.id, Probe_Actor) == a)
	testing.expect(t, actor_props(&world, a.id, Transform) == &a.transform)
	testing.expect(t, actor_props(&world, a.id, Probe_Box) == &a.box)
	testing.expect_value(t, probe_box_live, 1)
	testing.expect_value(t, a.position, Vec3{1, 2, 3})
}

@(test)
actor_hooks_run_with_self :: proc(t: ^testing.T) {
	world := world_create(nil)
	defer world_destroy(&world)

	a := world_add_actor(
		&world,
		Probe_Ticker{actor = actor_hooks(Probe_Ticker, tick = probe_tick, fixed_tick = probe_fixed_tick)},
	)
	world_update(&world, 0.5)
	world_fixed_update(&world, 1.0 / 60.0)
	testing.expect_value(t, a.ticks, 1)
	testing.expect_value(t, a.dt, f32(0.5))
	testing.expect_value(t, a.fixed_ticks, 1)
	testing.expect(t, a.seen == a)
}

@(test)
transform_is_normalized_and_always_present :: proc(t: ^testing.T) {
	world := world_create(nil)
	defer world_destroy(&world)

	// Zero scale and rotation are "unset": normalized like spawn.
	a := world_add_actor(&world, Probe_Actor{transform = Transform{position = {1, 2, 3}}})
	transform := actor_props(&world, a.id, Transform)
	testing.expect(t, transform != nil)
	testing.expect_value(t, transform.scale, Vec3{1, 1, 1})
	testing.expect_value(t, transform.rotation, linalg.QUATERNIONF32_IDENTITY)

	// No Transform in the struct: a default one is still attached.
	b := world_add_actor(&world, Probe_Ticker{})
	default_transform := actor_props(&world, b.id, Transform)
	testing.expect(t, default_transform != nil)
	testing.expect_value(t, default_transform.scale, Vec3{1, 1, 1})
}

@(test)
embedded_prop_replace_and_remove_stay_in_block :: proc(t: ^testing.T) {
	probe_box_live = 0
	probe_box_added_count = 0
	probe_box_removed_count = 0
	world := world_create(nil)
	defer world_destroy(&world)
	register_props(&world, Probe_Box, probe_box_added, probe_box_removed)

	a := world_add_actor(&world, Probe_Actor{box = Probe_Box{hp = 4}})
	testing.expect_value(t, probe_box_live, 1)

	// Replacing keeps the same memory: the Prop is written in place.
	actor_add_props(&world, a.id, Probe_Box{hp = 9})
	testing.expect_value(t, probe_box_live, 1)
	testing.expect_value(t, probe_box_added_count, 2)
	testing.expect_value(t, probe_box_removed_count, 1)
	testing.expect(t, actor_props(&world, a.id, Probe_Box) == &a.box)
	testing.expect_value(t, a.box.hp, 9)

	// Removing an embedded Prop must not free the actor's block; the tracking allocator checks the rest.
	actor_remove_props(&world, a.id, Probe_Box)
	testing.expect_value(t, probe_box_live, 0)
	testing.expect(t, actor_props(&world, a.id, Probe_Box) == nil)
	testing.expect(t, world_get(&world, a.id, Probe_Actor) == a)
}

@(test)
destroy_hook_runs_once_before_props_go :: proc(t: ^testing.T) {
	probe_box_live = 0
	probe_dying_count = 0
	world := world_create(nil)
	defer world_destroy(&world)
	register_props(&world, Probe_Box, probe_box_added, probe_box_removed)

	dying := world_add_actor(
		&world,
		Probe_Dying{actor = actor_hooks(Probe_Dying, destroy = probe_dying_destroy), box = Probe_Box{hp = 7}},
	)
	handle := dying.id
	world_destroy_actor(&world, handle)
	world_destroy_actor(&world, handle) // stale id: no second hook
	testing.expect_value(t, probe_dying_count, 1)
	testing.expect_value(t, probe_dying_hp, 7)
	testing.expect_value(t, probe_box_live, 0)
	testing.expect(t, !world_valid(&world, handle))
}

@(test)
world_get_find_count_by_struct_type :: proc(t: ^testing.T) {
	world := world_create(nil)
	defer world_destroy(&world)

	p := world_add_actor(&world, Probe_Actor{})
	ticker := world_add_actor(&world, Probe_Ticker{})

	testing.expect(t, world_get(&world, p.id, Probe_Ticker) == nil)
	testing.expect(t, world_get(&world, ticker.id, Probe_Actor) == nil)
	testing.expect(t, world_find(&world, Probe_Actor) == p)
	testing.expect_value(t, world_count_of(&world, Probe_Ticker), 1)
	testing.expect_value(t, world_count_of(&world, Probe_Actor), 1)
}

@(test)
struct_actors_coexist_with_typed_actors :: proc(t: ^testing.T) {
	world := world_create(nil)
	defer world_destroy(&world)

	counter := register_type(&world, Fixed_Counter, nil, fixed_counter_tick, nil, fixed_counter_fixed_tick)
	old_id, old_state := spawn_typed(&world, counter, Fixed_Counter{})
	probe := world_add_actor(
		&world,
		Probe_Ticker{actor = actor_hooks(Probe_Ticker, tick = probe_tick, fixed_tick = probe_fixed_tick)},
	)

	world_update(&world, 0.25)
	world_fixed_update(&world, 0.25)
	testing.expect_value(t, old_state.ticks, 1)
	testing.expect_value(t, old_state.fixed_ticks, 1)
	testing.expect_value(t, probe.ticks, 1)
	testing.expect_value(t, probe.fixed_ticks, 1)

	testing.expect(t, world_get_state(&world, old_id, Fixed_Counter) == old_state)
	testing.expect(t, world_get(&world, old_id, Probe_Ticker) == nil)
	testing.expect_value(t, world_count(&world, counter), 1)
	testing.expect_value(t, world_count_of(&world, Probe_Ticker), 1)
}

@(test)
embedded_layout_requires_actor_first :: proc(t: ^testing.T) {
	world := world_create(nil)
	defer world_destroy(&world)

	_, ok := embedded_layout(&world, Probe_Bad)
	testing.expect(t, !ok)
	_, ok_good := embedded_layout(&world, Probe_Ticker)
	testing.expect(t, ok_good)
}
