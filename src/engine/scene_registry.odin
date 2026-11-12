// Scene registry: a Scene_Entry maps a name to its Odin constructor. Every scene
// has a JSON definition src/scenes/<name>/scene.json (display name, start camera;
// data scenes also list their entities). An entry without `make` is run entirely
// from its JSON by data_scene.
package engine

import "core:log"
import "core:strings"

Scene_Entry :: struct {
	name: string,
	make: proc() -> Scene, // nil: the JSON alone defines the scene
}

scene_path :: proc(name: string) -> string {
	return strings.concatenate({"src/scenes/", name, "/scene.json"}, context.temp_allocator)
}

// Builds the named scene; false when the name is not registered.
scene_lookup :: proc(entries: []Scene_Entry, name: string) -> (Scene, bool) {
	for entry in entries {
		if entry.name != name do continue
		path := scene_path(name)
		if entry.make == nil do return data_scene(strings.clone(path)), true

		scene := entry.make()
		// Code scenes only borrow the name and camera; the file is not kept.
		file: Scene_File
		if scene_file_load(&file, path) {
			defer scene_file_destroy(&file)
			if file.def.name != "" do scene.name = strings.clone(file.def.name)
			if camera, ok := file.def.camera.?; ok {
				look_at, _ := camera.look_at.?
				scene.start_camera = Camera_Start{camera.position, look_at}
			}
		} else {
			log.warnf("scene %q: no definition file, using built-in defaults", name)
		}
		return scene, true
	}

	return {}, false
}
