// Data scene: everything comes from a JSON definition (engine/scene_def.odin).
// The registry sets Scene.definition to the file path; no code per scene.
package engine

import "core:log"
import "gfx"

Data_State :: struct {
	file:  Scene_File,
	world: World,
}

data_scene :: proc(definition: string) -> Scene {
	return {name = definition, definition = definition, create = data_create, tick = data_tick, destroy = data_destroy}
}

data_create :: proc(scene: ^Scene, ctx: ^Context) -> bool {
	state := new(Data_State)
	if !scene_file_load(&state.file, scene.definition) {
		free(state)
		return false
	}
	scene.state = state
	if state.file.def.name != "" do scene.name = state.file.def.name
	state.world = world_create(&ctx.gfx)
	world_spawn_scene(&state.world, &state.file.def)
	return true
}

data_tick :: proc(scene: ^Scene, ctx: ^Context, delta_time: f32) {
	state := cast(^Data_State)scene.state
	world_update(&state.world, delta_time)
	world_render(&state.world)
}

data_destroy :: proc(scene: ^Scene, ctx: ^Context) {
	state := cast(^Data_State)scene.state
	world_destroy(&state.world)
	scene_file_destroy(&state.file)
	free(state)
}
