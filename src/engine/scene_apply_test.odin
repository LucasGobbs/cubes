package engine

import "core:encoding/json"
import "core:testing"

@(private = "file")
test_def :: proc(entities: ..Entity_Def) -> Scene_Def {
	return Scene_Def{name = "test", entities = entities}
}

@(test)
apply_keeps_entity_id_and_moves_transform :: proc(t: ^testing.T) {
	world := world_create(nil)
	defer world_destroy(&world)

	def := test_def({name = "a", position = {1, 2, 3}})
	ids := world_spawn_scene(&world, &def)
	testing.expect_value(t, len(ids), 1)

	def.entities[0].position = {4, 5, 6}
	testing.expect(t, world_apply_scene(&world, &def))

	id, found := world_find_by_name(&world, "a")
	testing.expect(t, found)
	testing.expect_value(t, id, ids[0])
	testing.expect_value(t, entity_get_component(&world, id, Transform).position, [3]f32{4, 5, 6})
}

@(test)
apply_spawns_new_and_destroys_removed :: proc(t: ^testing.T) {
	world := world_create(nil)
	defer world_destroy(&world)

	def := test_def({name = "a"}, {name = "b"})
	world_spawn_scene(&world, &def)

	def.entities = {{name = "a"}, {name = "c"}}
	world_apply_scene(&world, &def)

	_, has_b := world_find_by_name(&world, "b")
	_, has_c := world_find_by_name(&world, "c")
	testing.expect(t, !has_b)
	testing.expect(t, has_c)
	testing.expect_value(t, len(world_entities(&world)), 2)
}

@(test)
apply_keeps_health_and_removes_absent_component :: proc(t: ^testing.T) {
	world := world_create(nil)
	defer world_destroy(&world)

	def := test_def({name = "hp", health = Health_Def{current = 5, max = 10}})
	world_spawn_scene(&world, &def)
	id, _ := world_find_by_name(&world, "hp")

	def.entities[0].health = nil
	world_apply_scene(&world, &def)
	testing.expect(t, entity_get_component(&world, id, Health) == nil)
}

@(test)
round_trip_json_is_stable :: proc(t: ^testing.T) {
	world := world_create(nil)
	defer world_destroy(&world)

	def := test_def({name = "a", position = {1, 2, 3}, scale = {2, 2, 2}, health = Health_Def{current = 4, max = 8}})
	world_spawn_scene(&world, &def)

	out := world_to_def(&world, &def)
	first, err1 := json.marshal(out, allocator = context.temp_allocator)
	testing.expect_value(t, err1, nil)

	back: Scene_Def
	err2 := json.unmarshal(first, &back, allocator = context.temp_allocator)
	testing.expect_value(t, err2, nil)

	second, err3 := json.marshal(back, allocator = context.temp_allocator)
	testing.expect_value(t, err3, nil)
	testing.expect_value(t, string(first), string(second))
}
