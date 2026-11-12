// Data scene: everything comes from a JSON definition (engine/scene_def.odin).
// The registry sets Scene.definition to the file path; no code per scene.
package data_scene

import "core:log"
import engine "../../engine"
import gbbfx "../../gbbfx"
import scenekit "../../scenekit"

Data_State :: struct {
	file:  engine.Scene_File,
	world: engine.World,
}

data_scene :: proc(definition: string) -> scenekit.Scene {
	return {name = definition, definition = definition, create = data_create, tick = data_tick, destroy = data_destroy}
}

data_create :: proc(scene: ^scenekit.Scene, gfx: ^gbbfx.Gfx) -> bool {
	state := new(Data_State)
	if !engine.scene_file_load(&state.file, scene.definition) {
		free(state)
		return false
	}
	scene.state = state
	if state.file.def.name != "" do scene.name = state.file.def.name
	state.world = engine.world_create(gfx)
	engine.world_spawn_scene(&state.world, &state.file.def)
	return true
}

data_tick :: proc(scene: ^scenekit.Scene, gfx: ^gbbfx.Gfx, delta_time: f32) {
	state := cast(^Data_State)scene.state
	engine.world_update(&state.world, delta_time)
	engine.world_render(&state.world)
}

data_destroy :: proc(scene: ^scenekit.Scene, gfx: ^gbbfx.Gfx) {
	state := cast(^Data_State)scene.state
	engine.world_destroy(&state.world)
	engine.scene_file_destroy(&state.file)
	free(state)
}
