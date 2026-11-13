package engine

import "core:testing"

// Ctrl+S path: world_save_scene writes a file that scene_file_load reads back.
@(test)
save_writes_file_that_loads_back :: proc(t: ^testing.T) {
	world := world_create(nil)
	defer world_destroy(&world)

	def := Scene_Def{name = "test", entities = {{name = "a", position = {1, 2, 3}}}}
	world_spawn_scene(&world, &def)

	path := "/tmp/cubes_save_test.json"
	testing.expect(t, world_save_scene(&world, &def, path))

	file: Scene_File
	testing.expect(t, scene_file_load(&file, path))
	defer scene_file_destroy(&file)
	testing.expect_value(t, len(file.def.entities), 1)
	testing.expect_value(t, file.def.entities[0].name, "a")
	testing.expect_value(t, file.def.entities[0].position, [3]f32{1, 2, 3})
}
