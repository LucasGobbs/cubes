// Scene registry: a Scene_Entry maps a name to its Odin constructor. Every scene
// has an optional JSON definition src/scenes/<name>/scene.json (display name, start
// camera; data scenes also list their actors). An entry without `make` is run entirely
// from its JSON by data_scene.
package engine

import "core:strings"

Scene_Entry :: struct {
	name:  string,
	group: string, // number-key group and Q/E cycle; "" = a group of its own named after `name`
	make:  proc() -> Scene, // nil: the JSON alone defines the scene
}

scene_path :: proc(name: string) -> string {
	return strings.concatenate({"src/scenes/", name, "/scene.json"}, context.temp_allocator)
}

// Builds the named scene; false when the name is not registered.
scene_lookup :: proc(entries: []Scene_Entry, name: string) -> (Scene, bool) {
	for entry in entries {
		if entry.name != name do continue
		path := scene_path(name)
		if entry.make == nil do return data_scene(name, strings.clone(path)), true

		scene := entry.make()
		// Code scenes may omit the file; built-in defaults stand in for it. An invalid file
		// was already logged by scene_file_load, and the defaults stand in too.
		file: Scene_File
		if scene_file_load(&file, path) == .Ok {
			defer scene_file_destroy(&file)
			if file.def.name != "" do scene.name = strings.clone(file.def.name)
			if camera, ok := file.def.camera.?; ok {
				look_at, _ := camera.look_at.?
				scene.start_camera = Camera_Start{camera.position, look_at}
			}
		}
		return scene, true
	}

	return {}, false
}
