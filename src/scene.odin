// Scene registry: maps scene names (CLI argument, number-key order) to their
// constructors. Every scene has a JSON definition src/scenes/<name>/scene.json
// (display name, start camera; data scenes also list their entities). A scene
// with `make` is Odin code in src/scenes/<name>/; one without is run entirely
// from its JSON by engine.data_scene. Shared plumbing lives in src/engine.
package main

import "core:log"
import "core:strings"
import engine "engine"
import benchmark "scenes/benchmark"
import editor "scenes/editor"
import forest_naive "scenes/forest_naive"
import forest_instanced "scenes/forest_instanced"
import game "scenes/game"
import models "scenes/models"
import platform "scenes/platform"
import simple "scenes/simple"
import skinned "scenes/skinned"

SceneEntry :: struct {
	name: string,
	make: proc() -> engine.Scene, // nil: the JSON alone defines the scene
}

SCENES := [?]SceneEntry {
	{name = "simple", make = simple.simple_scene},
	{name = "editor", make = editor.editor_scene},
	{name = "models", make = models.models_scene},
	{name = "skinned", make = skinned.skinned_scene},
	{name = "postfx"},
	{name = "game", make = game.game_scene},
	{name = "platform", make = platform.platform_scene},
	{name = "forest_naive", make = forest_naive.forest_naive_scene},
	{name = "forest_instanced", make = forest_instanced.forest_instanced_scene},
	{name = "benchmark", make = benchmark.benchmark_scene},
}

scene_path :: proc(name: string) -> string {
	return strings.concatenate({"src/scenes/", name, "/scene.json"}, context.temp_allocator)
}

scene_lookup :: proc(name: string) -> (engine.Scene, bool) {
	for entry in SCENES {
		if entry.name != name do continue
		path := scene_path(name)
		if entry.make == nil do return engine.data_scene(strings.clone(path)), true

		scene := entry.make()
		// Code scenes only borrow the name and camera; the file is not kept.
		file: engine.Scene_File
		if engine.scene_file_load(&file, path) {
			defer engine.scene_file_destroy(&file)
			if file.def.name != "" do scene.name = strings.clone(file.def.name)
			if camera, ok := file.def.camera.?; ok {
				look_at, _ := camera.look_at.?
				scene.start_camera = engine.Camera_Start{camera.position, look_at}
			}
		} else {
			log.warnf("scene %q: no definition file, using built-in defaults", name)
		}
		return scene, true
	}

	return {}, false
}
