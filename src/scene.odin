// Scene registry for the host. Scenes are grouped: number keys pick a group, Q/E step within it.
package main

import engine "engine"
import boat "scenes/boat"
import benchmark "scenes/benchmark"
import forest_naive "scenes/forest_naive"
import forest_instanced "scenes/forest_instanced"
import city "scenes/city"
import game "scenes/game"
import physics "scenes/physics"
import scriptdemo "scenes/scriptdemo"
import skinned "scenes/skinned"
import stencil "scenes/stencil"
// cubes:imports

SCENES := [?]engine.Scene_Entry {
	{name = "boat", group = "sea", make = boat.boat_scene},
	{name = "benchmark", group = "sea", make = benchmark.benchmark_scene},
	{name = "benchmark_lua", group = "sea", make = benchmark.benchmark_lua_scene},
	{name = "benchmark_lua_batch", group = "sea", make = benchmark.benchmark_lua_batch_scene},
	{name = "forest_naive", group = "forest", make = forest_naive.forest_naive_scene},
	{name = "forest_instanced", group = "forest", make = forest_instanced.forest_instanced_scene},
	{name = "scriptdemo", group = "script", make = scriptdemo.scriptdemo_scene},
	{name = "scriptdemo_batch", group = "script", make = scriptdemo.scriptdemo_batch_scene},
	{name = "scriptdemo_odin", group = "script", make = scriptdemo.scriptdemo_odin_scene},
	{name = "scriptdemo_balls", group = "script", make = scriptdemo.scriptdemo_balls_scene},
	{name = "physics", group = "physics", make = physics.physics_scene},
	{name = "data_physics", group = "physics"},
	{name = "skinned", group = "demo", make = skinned.skinned_scene},
	{name = "game", group = "demo", make = game.game_scene},
	{name = "stencil", group = "demo", make = stencil.stencil_scene},
	{name = "city", group = "city", make = city.city_scene},
	// cubes:scenes
}
