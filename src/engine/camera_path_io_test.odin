package engine

import "core:log"
import "core:os"
import "core:testing"
import gfx "gfx"

@(test)
camera_path_json_round_trip :: proc(t: ^testing.T) {
	keys := [?]gfx.Camera_Key {
		{time = 0, position = {1536, 110, 1500}, target = {1536, 40, 1100}},
		{time = 3, position = {1200, 90, 1100}, target = {1536, 40, 800}},
	}
	path := "/tmp/cubes_camera_path_roundtrip.path.json"
	testing.expect(t, camera_path_save(path, gfx.Camera_Path{keys = keys[:], ease = true}))
	loaded, ok := camera_path_load(path)
	testing.expect(t, ok)
	defer delete(loaded.keys)
	testing.expect(t, loaded.ease)
	testing.expect_value(t, len(loaded.keys), len(keys))
	for k, i in keys {
		testing.expect(t, loaded.keys[i] == k)
	}
	os.remove(path)
}

@(test)
camera_path_json_rejects_unordered_times :: proc(t: ^testing.T) {
	context.logger = log.nil_logger() // the rejection logs an error; the test runner counts that as a failure
	path := "/tmp/cubes_camera_path_bad.path.json"
	testing.expect(t, os.write_entire_file_from_string(path, `{"keys":[{"t":2,"pos":[0,0,0],"target":[0,0,-1]},{"t":1,"pos":[0,0,0],"target":[0,0,-1]}],"ease":false}`) == nil)
	_, ok := camera_path_load(path)
	testing.expect(t, !ok)
	os.remove(path)
}
