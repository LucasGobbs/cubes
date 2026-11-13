package engine

import "core:math"
import "core:math/linalg"
import "core:strings"
import "core:testing"

@(test)
stale_id_is_invalid_after_slot_reuse :: proc(t: ^testing.T) {
	world := World{}
	defer world_destroy(&world)

	a := spawn(&world)
	world_destroy_entity(&world, a)
	b := spawn(&world)

	testing.expect_value(t, b.index, a.index)
	testing.expect(t, b.generation != a.generation)
	testing.expect(t, !world_valid(&world, a))
	testing.expect(t, entity_get_component(&world, a, Transform) == nil)
	testing.expect(t, world_valid(&world, b))
}

@(test)
spawn_normalizes_transform :: proc(t: ^testing.T) {
	world := World{}
	defer world_destroy(&world)

	id := spawn(&world, Transform{position = {1, 2, 3}})
	transform := entity_get_component(&world, id, Transform)
	testing.expect(t, transform != nil)
	testing.expect_value(t, transform.position, Vec3{1, 2, 3})
	testing.expect_value(t, transform.scale, Vec3{1, 1, 1})
	testing.expect_value(t, transform.rotation, linalg.QUATERNIONF32_IDENTITY)
}

@(test)
set_transform_replaces_and_normalizes :: proc(t: ^testing.T) {
	world := World{}
	defer world_destroy(&world)

	id := spawn(&world)
	entity_set_transform(&world, id, position = {1, 2, 3}, scale = {})
	transform := entity_transform(&world, id)
	testing.expect_value(t, transform.position, Vec3{1, 2, 3})
	testing.expect_value(t, transform.scale, Vec3{1, 1, 1})
	testing.expect_value(t, transform.rotation, linalg.QUATERNIONF32_IDENTITY)
}

@(test)
add_replaces_component_of_same_type :: proc(t: ^testing.T) {
	world := World{}
	defer world_destroy(&world)

	id := spawn(&world, Transform{position = {1, 0, 0}})
	slot := &world.slots[id.index]
	before := len(slot.components)

	entity_add_component(&world, id, Transform{position = {4, 5, 6}})

	testing.expect_value(t, len(slot.components), before)
	transform := entity_get_component(&world, id, Transform)
	testing.expect_value(t, transform.position, Vec3{4, 5, 6})
}

@(test)
health_get_and_replace :: proc(t: ^testing.T) {
	world := World{}
	defer world_destroy(&world)

	id := spawn(&world, Health{current = 100, max = 100})
	health := entity_get_component(&world, id, Health)
	testing.expect(t, health != nil)
	if health == nil do return
	testing.expect_value(t, health.current, 100)

	slot := &world.slots[id.index]
	before := len(slot.components)
	entity_add_component(&world, id, Health{current = 40, max = 100})

	testing.expect_value(t, len(slot.components), before)
	health = entity_get_component(&world, id, Health)
	testing.expect_value(t, health.current, 40)
	testing.expect_value(t, health.max, 100)
}

@(test)
destroy_invalid_id_is_noop :: proc(t: ^testing.T) {
	world := World{}
	defer world_destroy(&world)

	id := spawn(&world)
	world_destroy_entity(&world, Entity_Id{index = 99, generation = 1})
	world_destroy_entity(&world, Entity_Id{})
	world_destroy_entity(&world, id)
	world_destroy_entity(&world, id) // second destroy of the same id

	testing.expect_value(t, len(world.free), 1)
	testing.expect(t, !world_valid(&world, id))
}

@(test)
direction_angles_match_camera_convention :: proc(t: ^testing.T) {
	// gfx.Camera looks along (cos yaw * cos pitch, sin pitch, sin yaw * cos pitch).
	yaw, pitch := direction_angles(Vec3{0, 0, -2})
	testing.expect(t, math.abs(yaw + math.PI / 2) < 1e-5)
	testing.expect(t, math.abs(pitch) < 1e-5)

	yaw, pitch = direction_angles(Vec3{0, 1, 0})
	testing.expect(t, math.abs(pitch - math.PI / 2) < 1e-5)

	yaw, pitch = direction_angles(Vec3{})
	testing.expect_value(t, yaw, 0)
	testing.expect_value(t, pitch, 0)
}

@(test)
sprite_frame_loops_and_holds :: proc(t: ^testing.T) {
	anim := Sprite_Anim{first = 0, last = 3, fps = 4, loop = true}
	anim.time = 0.30
	testing.expect_value(t, sprite_frame(anim), 1)
	anim.time = 1.1
	testing.expect_value(t, sprite_frame(anim), 0)

	anim.loop = false
	anim.time = 5
	testing.expect_value(t, sprite_frame(anim), 3)
}

@(test)
find_by_name_follows_spawn_and_destroy :: proc(t: ^testing.T) {
	world := World{}
	defer world_destroy(&world)

	id := spawn(&world, Name{value = "hero"})
	found, ok := world_find_by_name(&world, "hero")
	testing.expect(t, ok)
	testing.expect_value(t, found, id)
	_, missing := world_find_by_name(&world, "villain")
	testing.expect(t, !missing)

	world_destroy_entity(&world, id)
	_, stale := world_find_by_name(&world, "hero")
	testing.expect(t, !stale)
}

@(test)
name_survives_freeing_source_and_replace :: proc(t: ^testing.T) {
	world := World{}
	defer world_destroy(&world)

	source := strings.clone("hero")
	id := spawn(&world, Name{value = source})
	delete(source)
	found, ok := world_find_by_name(&world, "hero")
	testing.expect(t, ok && found == id)

	// Replacing frees the old clone; the leak checker catches a miss.
	entity_add_component(&world, id, Name{value = "boss"})
	_, old := world_find_by_name(&world, "hero")
	testing.expect(t, !old)
	_, renamed := world_find_by_name(&world, "boss")
	testing.expect(t, renamed)
}

@(test)
entities_list_in_slot_order :: proc(t: ^testing.T) {
	world := World{}
	defer world_destroy(&world)

	a := spawn(&world, Name{value = "a"})
	b := spawn(&world)
	c := spawn(&world, Name{value = "c"})
	world_destroy_entity(&world, b)
	d := spawn(&world) // reuses b's slot, so it sits between a and c

	list := world_entities(&world)
	testing.expect_value(t, len(list), 3)
	if len(list) != 3 do return
	testing.expect_value(t, list[0], a)
	testing.expect_value(t, list[1], d)
	testing.expect_value(t, list[2], c)
}

@(test)
remove_sprite_component :: proc(t: ^testing.T) {
	world := World{}
	defer world_destroy(&world)

	id := spawn(&world, Sprite{texture = "static/none.png", layer = 2})
	testing.expect(t, entity_get_component(&world, id, Sprite) != nil)
	entity_remove_component(&world, id, Sprite)
	testing.expect(t, entity_get_component(&world, id, Sprite) == nil)
	testing.expect(t, entity_transform(&world, id) != nil)
}
