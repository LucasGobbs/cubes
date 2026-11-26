package engine

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:testing"

@(private = "file")
test_def :: proc(actors: ..Actor_Def) -> Scene_Def {
	return Scene_Def{name = "test", actors = actors}
}

@(test)
apply_keeps_actor_id_and_moves_transform :: proc(t: ^testing.T) {
	world := world_create(nil)
	defer world_destroy(&world)

	def := test_def({name = "a", position = {1, 2, 3}})
	ids := world_spawn_scene(&world, &def)
	testing.expect_value(t, len(ids), 1)

	def.actors[0].position = {4, 5, 6}
	testing.expect(t, world_apply_scene(&world, &def, nil))

	id, found := world_find_by_name(&world, "a")
	testing.expect(t, found)
	testing.expect_value(t, id, ids[0])
	testing.expect_value(t, actor_props(&world, id, Transform).position, [3]f32{4, 5, 6})
}

@(test)
apply_spawns_new_and_destroys_removed :: proc(t: ^testing.T) {
	world := world_create(nil)
	defer world_destroy(&world)

	def := test_def({name = "a"}, {name = "b"})
	world_spawn_scene(&world, &def)

	def.actors = {{name = "a"}, {name = "c"}}
	world_apply_scene(&world, &def, nil)

	_, has_b := world_find_by_name(&world, "b")
	_, has_c := world_find_by_name(&world, "c")
	testing.expect(t, !has_b)
	testing.expect(t, has_c)
	testing.expect_value(t, len(world_actors(&world)), 2)
}

@(test)
apply_keeps_health_and_removes_absent_prop :: proc(t: ^testing.T) {
	world := world_create(nil)
	defer world_destroy(&world)

	def := test_def({name = "hp", health = Health_Def{current = 5, max = 10}})
	world_spawn_scene(&world, &def)
	id, _ := world_find_by_name(&world, "hp")

	def.actors[0].health = nil
	world_apply_scene(&world, &def, nil)
	testing.expect(t, actor_props(&world, id, Health) == nil)
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

// Writes text to a temp definition file and parses it; the caller destroys file.
@(private = "file")
p8_load :: proc(t: ^testing.T, name, text: string, file: ^Scene_File) -> Scene_File_Status {
	path := fmt.tprintf("/tmp/cubes_p8_%s.json", name)
	testing.expect(t, os.write_entire_file_from_string(path, text) == nil)
	defer _ = os.remove(path)
	return scene_file_load(file, path)
}

P8_PROPS_JSON :: `{"name": "p8", "stage": {"fog": {"color": [0.5, 0.5, 0.6], "distance": 300}, "shadows": false, "sun_direction": [0, -1, 0], "uncapped": true, "grade": {"exposure": 0.5, "contrast": 1.1}}, "actors": [
	{"name": "ball", "position": [0, 3, 0], "collider": {"shape": "sphere", "radius": 0.5, "density": 2}},
	{"name": "floor", "collider": {"shape": "box", "half": [10, 0.5, 10], "body": "static"}}
]}`

P8_BALL_JSON :: `{"name": "p8", "actors": [{"name": "ball", "collider": {"shape": "sphere", "radius": 0.5, "density": 2}}]}`
P8_BALL_DENSITY_4_JSON :: `{"name": "p8", "actors": [{"name": "ball", "collider": {"shape": "sphere", "radius": 0.5, "density": 4}}]}`

@(test)
p8_props_from_json :: proc(t: ^testing.T) {
	file: Scene_File
	defer scene_file_destroy(&file)
	testing.expect_value(t, p8_load(t, "props", P8_PROPS_JSON, &file), Scene_File_Status.Ok)

	world := world_create(nil)
	defer world_destroy(&world)
	world_spawn_scene(&world, &file.def)

	ball, _ := world_find_by_name(&world, "ball")
	if collider := actor_props(&world, ball, Collider); collider != nil {
		sphere, is_sphere := collider.shape.(Sphere)
		testing.expect(t, is_sphere)
		testing.expect_value(t, sphere.radius, f32(0.5))
		testing.expect_value(t, collider.body, Body_Kind.Dynamic)
		testing.expect_value(t, collider.density, f32(2))
	} else {
		testing.expect(t, false, "ball has no Collider")
	}

	floor, _ := world_find_by_name(&world, "floor")
	if collider := actor_props(&world, floor, Collider); collider != nil {
		box, is_box := collider.shape.(Box)
		testing.expect(t, is_box)
		testing.expect_value(t, box.half, [3]f32{10, 0.5, 10})
		testing.expect_value(t, collider.body, Body_Kind.Static)
	} else {
		testing.expect(t, false, "floor has no Collider")
	}

	stage := world.stage
	fog, has_fog := stage.fog.?
	testing.expect(t, has_fog)
	testing.expect_value(t, fog.color, [3]f32{0.5, 0.5, 0.6})
	testing.expect_value(t, fog.distance, f32(300))
	shadows, has_shadows := stage.shadows.?
	testing.expect(t, has_shadows && !shadows)
	sun, has_sun := stage.sun_direction.?
	testing.expect(t, has_sun && sun == [3]f32{0, -1, 0})
	testing.expect(t, stage.uncapped)
	grade, has_grade := stage.grade.?
	testing.expect(t, has_grade)
	testing.expect_value(t, grade.exposure, f32(0.5))
	testing.expect_value(t, grade.contrast, f32(1.1))
	testing.expect_value(t, grade.saturation, f32(1)) // omitted in JSON: default 1
}

@(test)
p8_save_load_round_trip :: proc(t: ^testing.T) {
	file: Scene_File
	defer scene_file_destroy(&file)
	testing.expect_value(t, p8_load(t, "rt_src", P8_PROPS_JSON, &file), Scene_File_Status.Ok)

	world := world_create(nil)
	defer world_destroy(&world)
	world_spawn_scene(&world, &file.def)

	path := "/tmp/cubes_p8_roundtrip.json"
	defer _ = os.remove(path)
	testing.expect(t, world_save_scene(&world, &file.def, path))

	saved: Scene_File
	defer scene_file_destroy(&saved)
	testing.expect_value(t, scene_file_load(&saved, path), Scene_File_Status.Ok)

	back := world_create(nil)
	defer world_destroy(&back)
	world_spawn_scene(&back, &saved.def)

	for name in ([]string{"ball", "floor"}) {
		id, _ := world_find_by_name(&world, name)
		back_id, found := world_find_by_name(&back, name)
		testing.expect(t, found)
		if collider := actor_props(&world, id, Collider); collider != nil {
			testing.expect_value(t, actor_props(&back, back_id, Collider)^, collider^)
		}
	}
	testing.expect_value(t, back.stage, world.stage)
}

@(test)
p8_hot_reload_updates_density_in_place :: proc(t: ^testing.T) {
	first, second: Scene_File
	defer scene_file_destroy(&first)
	defer scene_file_destroy(&second)
	testing.expect_value(t, p8_load(t, "density1", P8_BALL_JSON, &first), Scene_File_Status.Ok)
	testing.expect_value(t, p8_load(t, "density2", P8_BALL_DENSITY_4_JSON, &second), Scene_File_Status.Ok)

	world := world_create(nil)
	defer world_destroy(&world)
	world_spawn_scene(&world, &first.def)
	id, _ := world_find_by_name(&world, "ball")

	testing.expect(t, world_apply_scene(&world, &second.def, &first.def))
	id2, found := world_find_by_name(&world, "ball")
	testing.expect(t, found)
	testing.expect_value(t, id2, id)
	testing.expect_value(t, actor_props(&world, id, Collider).density, f32(4))
}

@(test)
p8_hot_reload_removes_only_file_defined_collider :: proc(t: ^testing.T) {
	with_collider, without: Scene_File
	defer scene_file_destroy(&with_collider)
	defer scene_file_destroy(&without)
	testing.expect_value(t, p8_load(t, "rm_with", P8_BALL_JSON, &with_collider), Scene_File_Status.Ok)
	testing.expect_value(t, p8_load(t, "rm_without", `{"name": "p8", "actors": [{"name": "ball"}, {"name": "floor2"}]}`, &without), Scene_File_Status.Ok)

	world := world_create(nil)
	defer world_destroy(&world)
	world_spawn_scene(&world, &with_collider.def)
	// Code-added Collider on an actor the file names but never defined a Collider for: must survive.
	spawn(&world, Name{"floor2"}, Transform{}, Collider{shape = Box{half = {1, 1, 1}}, body = .Static})

	testing.expect(t, world_apply_scene(&world, &without.def, &with_collider.def))
	ball, _ := world_find_by_name(&world, "ball")
	testing.expect(t, actor_props(&world, ball, Collider) == nil)
	floor2, _ := world_find_by_name(&world, "floor2")
	testing.expect(t, actor_props(&world, floor2, Collider) != nil)
}

@(test)
p8_invalid_collider_is_invalid_status :: proc(t: ^testing.T) {
	context.logger = log.nil_logger()
	file: Scene_File
	testing.expect_value(t, p8_load(t, "bad_shape", `{"actors": [{"name": "x", "collider": {"shape": "cone"}}]}`, &file), Scene_File_Status.Invalid)
	testing.expect_value(t, p8_load(t, "bad_mismatch", `{"actors": [{"name": "x", "collider": {"shape": "sphere", "half": [1, 1, 1], "radius": 1}}]}`, &file), Scene_File_Status.Invalid)
	testing.expect_value(t, p8_load(t, "bad_static_sphere", `{"actors": [{"name": "x", "collider": {"shape": "sphere", "radius": 1, "body": "static"}}]}`, &file), Scene_File_Status.Invalid)
}

// Same assertion as the Collider test in world_test.odin, but the bodies come from JSON.
@(test)
p8_json_ball_rests_on_static_ground :: proc(t: ^testing.T) {
	file: Scene_File
	defer scene_file_destroy(&file)
	testing.expect_value(t, p8_load(t, "rest", `{"name": "p8", "actors": [
		{"name": "ground", "position": [0, -0.5, 0], "collider": {"shape": "box", "half": [10, 0.5, 10], "body": "static"}},
		{"name": "ball", "position": [0, 3, 0], "collider": {"shape": "sphere", "radius": 0.5}}
	]}`, &file), Scene_File_Status.Ok)

	world := world_create(nil)
	defer world_destroy(&world)
	world_spawn_scene(&world, &file.def)

	for _ in 0 ..< 120 do world_update(&world, 1.0 / 60.0)

	ball, _ := world_find_by_name(&world, "ball")
	transform := actor_transform(&world, ball)
	testing.expect(t, transform != nil)
	if transform != nil do testing.expect(t, transform.position.y >= 0.4 && transform.position.y <= 0.6)
}
