// Scene registry: maps scene names (CLI argument, number-key order) to their
// constructors. Each scene is a package in src/scenes/<name>/ whose scene.odin
// defines <name>_scene; shared plumbing lives in src/scenekit. main.odin runs
// the picked scene.
package main

import scenekit "scenekit"
import benchmark "scenes/benchmark"
import editor "scenes/editor"
import forest "scenes/forest"
import game "scenes/game"
import models "scenes/models"
import platform "scenes/platform"
import postfx "scenes/postfx"
import simple "scenes/simple"
import skinned "scenes/skinned"

SceneEntry :: struct {
	name: string,
	make: proc() -> scenekit.Scene,
}

SCENES := [?]SceneEntry {
	{"simple", simple.simple_scene},
	{"editor", editor.editor_scene},
	{"models", models.models_scene},
	{"skinned", skinned.skinned_scene},
	{"postfx", postfx.postfx_scene},
	{"game", game.game_scene},
	{"platform", platform.platform_scene},
	{"forest", forest.forest_scene},
	{"benchmark", benchmark.benchmark_scene},
}

scene_lookup :: proc(name: string) -> (scenekit.Scene, bool) {
	for scene in SCENES {
		if scene.name == name do return scene.make(), true
	}

	return {}, false
}
