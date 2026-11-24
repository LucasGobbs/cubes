package engine

import "core:log"
import "core:os"
import "core:testing"

// Ctrl+S path: world_save_scene writes a file that scene_file_load reads back.
@(test)
save_writes_file_that_loads_back :: proc(t: ^testing.T) {
	world := world_create(nil)
	defer world_destroy(&world)

	def := Scene_Def{name = "test", actors = {{name = "a", position = {1, 2, 3}}}}
	world_spawn_scene(&world, &def)

	path := "/tmp/cubes_save_test.json"
	testing.expect(t, world_save_scene(&world, &def, path))

	file: Scene_File
	testing.expect_value(t, scene_file_load(&file, path), Scene_File_Status.Ok)
	defer scene_file_destroy(&file)
	testing.expect_value(t, len(file.def.actors), 1)
	testing.expect_value(t, file.def.actors[0].name, "a")
	testing.expect_value(t, file.def.actors[0].position, [3]f32{1, 2, 3})
}

// Missing is a status, not an error: no log here, so odin test would fail on any log.errorf.
@(test)
scene_file_missing_status :: proc(t: ^testing.T) {
	path := "/tmp/cubes_p6_missing_no_such.json"
	_ = os.remove(path)
	file: Scene_File
	testing.expect_value(t, scene_file_load(&file, path), Scene_File_Status.Missing)
}

@(test)
scene_file_invalid_status :: proc(t: ^testing.T) {
	context.logger = log.nil_logger()
	path := "/tmp/cubes_p6_invalid.json"
	testing.expect(t, os.write_entire_file_from_string(path, "{ not json") == nil)
	defer _ = os.remove(path)
	file: Scene_File
	testing.expect_value(t, scene_file_load(&file, path), Scene_File_Status.Invalid)
}

// A data scene whose definition is missing fails to create (one error log names the scene; silenced here).
@(test)
data_scene_missing_definition_fails_create :: proc(t: ^testing.T) {
	context.logger = log.nil_logger()
	path := "/tmp/cubes_p6_missing_scene.json"
	_ = os.remove(path)
	scene := data_scene("p6_missing", path)
	testing.expect(t, !data_create(&scene, nil))
	testing.expect(t, scene.state == nil)
}
