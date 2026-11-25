// Camera path files (*.path.json): {"keys": [{"t": 0, "pos": [x, y, z], "target": [x, y, z]}, ...], "ease": true}.
// Keys need a non-empty list with strictly increasing t.
package engine

import "core:encoding/json"
import "core:log"
import "core:os"
import gfx "gfx"

@(private = "file") Camera_Path_Key_File :: struct {
	t:      f32,
	pos:    [3]f32,
	target: [3]f32,
}

@(private = "file") Camera_Path_File :: struct {
	keys: []Camera_Path_Key_File,
	ease: bool,
}

// Reads a path file; keys are allocated with context.allocator (free with delete(path.keys)). Logs and returns false on error.
camera_path_load :: proc(path: string) -> (result: gfx.Camera_Path, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		log.errorf("camera path %q: cannot read: %v", path, err)
		return
	}
	def: Camera_Path_File
	if json_err := json.unmarshal(data, &def, allocator = context.temp_allocator); json_err != nil {
		log.errorf("camera path %q: %v", path, json_err)
		return
	}
	if len(def.keys) == 0 {
		log.errorf("camera path %q: no keys", path)
		return
	}
	keys := make([]gfx.Camera_Key, len(def.keys))
	for k, i in def.keys {
		if i > 0 && k.t <= def.keys[i - 1].t {
			log.errorf("camera path %q: key %d time %v is not after key %d", path, i, k.t, i - 1)
			delete(keys)
			return
		}
		keys[i] = {time = k.t, position = k.pos, target = k.target}
	}
	return gfx.Camera_Path{keys = keys, ease = def.ease}, true
}

// Writes the path as pretty JSON. Logs and returns false on failure.
camera_path_save :: proc(path: string, p: gfx.Camera_Path) -> bool {
	def := Camera_Path_File {
		keys = make([]Camera_Path_Key_File, len(p.keys), context.temp_allocator),
		ease = p.ease,
	}
	for k, i in p.keys do def.keys[i] = {t = k.time, pos = k.position, target = k.target}
	data, err := json.marshal(def, {pretty = true, use_spaces = true, spaces = 2}, context.temp_allocator)
	if err != nil {
		log.errorf("camera path %q: %v", path, err)
		return false
	}
	if write_err := os.write_entire_file(path, data); write_err != nil {
		log.errorf("camera path %q: %v", path, write_err)
		return false
	}
	return true
}
