// Scene registry for the host. Order = number keys 1..9.
package main

import engine "engine"
import boat "scenes/boat"
import benchmark "scenes/benchmark"
import forest_naive "scenes/forest_naive"
import forest_instanced "scenes/forest_instanced"
import game "scenes/game"
import physics "scenes/physics"
import scriptdemo "scenes/scriptdemo"
import skinned "scenes/skinned"
import stencil "scenes/stencil"

SCENES := [?]engine.Scene_Entry {
	{name = "skinned", make = skinned.skinned_scene},
	{name = "game", make = game.game_scene},
	{name = "forest_naive", make = forest_naive.forest_naive_scene},
	{name = "forest_instanced", make = forest_instanced.forest_instanced_scene},
	{name = "benchmark", make = benchmark.benchmark_scene},
	{name = "boat", make = boat.boat_scene},
	{name = "physics", make = physics.physics_scene},
	{name = "stencil", make = stencil.stencil_scene},
	{name = "scriptdemo", make = scriptdemo.scriptdemo_scene},
	{name = "scriptdemo_batch", make = scriptdemo.scriptdemo_batch_scene},
	{name = "scriptdemo_odin", make = scriptdemo.scriptdemo_odin_scene},
}
