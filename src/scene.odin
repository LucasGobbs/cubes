// Scene registry for the host. Order = number keys 1..9,0 (first ten only).
// Scenes without `make` run entirely from src/scenes/<name>/scene.json.
package main

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

SCENES := [?]engine.Scene_Entry {
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
