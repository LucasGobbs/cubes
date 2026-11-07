package engine

import "core:math"
import "core:math/linalg"
import "core:testing"

@(test)
stale_id_is_invalid_after_slot_reuse :: proc(t: ^testing.T) {
	world := World{}
	defer world_destroy(&world)

	a := world_spawn(&world)
	world_destroy_entity(&world, a)
	b := world_spawn(&world)

	testing.expect_value(t, b.index, a.index)
	testing.expect(t, b.generation != a.generation)
	testing.expect(t, !world_valid(&world, a))
	testing.expect(t, world_get(&world, a, Transform) == nil)
	testing.expect(t, world_valid(&world, b))
}

@(test)
spawn_normalizes_transform :: proc(t: ^testing.T) {
	world := World{}
	defer world_destroy(&world)

	id := world_spawn(&world, Transform{position = {1, 2, 3}})
	transform := world_get(&world, id, Transform)
	testing.expect(t, transform != nil)
	testing.expect_value(t, transform.position, Vec3{1, 2, 3})
	testing.expect_value(t, transform.scale, Vec3{1, 1, 1})
	testing.expect_value(t, transform.rotation, linalg.QUATERNIONF32_IDENTITY)
}

@(test)
add_replaces_component_of_same_type :: proc(t: ^testing.T) {
	world := World{}
	defer world_destroy(&world)

	id := world_spawn(&world, Transform{position = {1, 0, 0}})
	slot := &world.slots[id.index]
	before := len(slot.components)

	world_add(&world, id, Transform{position = {4, 5, 6}})

	testing.expect_value(t, len(slot.components), before)
	transform := world_get(&world, id, Transform)
	testing.expect_value(t, transform.position, Vec3{4, 5, 6})
}

@(test)
health_get_and_replace :: proc(t: ^testing.T) {
	world := World{}
	defer world_destroy(&world)

	id := world_spawn(&world, Health{current = 100, max = 100})
	health := world_get(&world, id, Health)
	testing.expect(t, health != nil)
	if health == nil do return
	testing.expect_value(t, health.current, 100)

	slot := &world.slots[id.index]
	before := len(slot.components)
	world_add(&world, id, Health{current = 40, max = 100})

	testing.expect_value(t, len(slot.components), before)
	health = world_get(&world, id, Health)
	testing.expect_value(t, health.current, 40)
	testing.expect_value(t, health.max, 100)
}

@(test)
destroy_invalid_id_is_noop :: proc(t: ^testing.T) {
	world := World{}
	defer world_destroy(&world)

	id := world_spawn(&world)
	world_destroy_entity(&world, Entity_Id{index = 99, generation = 1})
	world_destroy_entity(&world, Entity_Id{})
	world_destroy_entity(&world, id)
	world_destroy_entity(&world, id) // second destroy of the same id

	testing.expect_value(t, len(world.free), 1)
	testing.expect(t, !world_valid(&world, id))
}

@(test)
direction_angles_match_camera_convention :: proc(t: ^testing.T) {
	// gbbfx.Camera looks along (cos yaw * cos pitch, sin pitch, sin yaw * cos pitch).
	yaw, pitch := direction_angles(Vec3{0, 0, -2})
	testing.expect(t, math.abs(yaw + math.PI / 2) < 1e-5)
	testing.expect(t, math.abs(pitch) < 1e-5)

	yaw, pitch = direction_angles(Vec3{0, 1, 0})
	testing.expect(t, math.abs(pitch - math.PI / 2) < 1e-5)

	yaw, pitch = direction_angles(Vec3{})
	testing.expect_value(t, yaw, 0)
	testing.expect_value(t, pitch, 0)
}
