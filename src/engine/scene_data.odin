// Data scene: everything comes from a JSON definition (engine/scene_def.odin).
// The registry sets Scene.definition to the file path; no code per scene.
// Hot reload: every RELOAD_INTERVAL the file's mtime is polled; on change the file is
// parsed into a new Scene_File and applied to the live World by name (world_apply_scene).
// A parse or apply failure logs and keeps the running state. Live edits are not saved
// unless asked: Ctrl+S (or data_scene_save) writes the World back to the definition.
package engine

import "core:log"
import "core:os"
import "core:strings"
import "core:time"
import "input"

RELOAD_INTERVAL :: 0.25 // seconds between mtime polls

Data_State :: struct {
	file:       Scene_File,
	world:      World,
	mtime:      time.Time,
	poll_timer: f32,
	ctrl, save: input.Button_Action,
	name:       string, // owned copy: Scene.name is read every frame, the file arena is freed on reload
}

data_scene :: proc(definition: string) -> Scene {
	return {
		name = definition,
		definition = definition,
		load = data_load,
		unload = data_unload,
		create = data_create,
		tick = data_tick,
		destroy = data_destroy,
		suspend = data_suspend,
		resume = data_resume,
	}
}

// Job thread: parses the definition, then decodes every model and texture it lists in parallel.
data_load :: proc(scene: ^Scene, lc: ^Load_Context) -> bool {
	state := new(Data_State)
	if !scene_file_load(&state.file, scene.definition) {
		free(state)
		return false
	}
	scene.state = state
	load_progress(lc, 0.1)
	asset_prefetch_def(lc, &state.file.def)
	return true
}

// A load that was dropped before create: its parsed file and unconsumed decodes.
data_unload :: proc(scene: ^Scene) {
	state := cast(^Data_State)scene.state
	asset_prefetch_discard_def(&state.file.def)
	scene_file_destroy(&state.file)
	free(state)
	scene.state = nil
}

data_create :: proc(scene: ^Scene, ctx: ^Context) -> bool {
	state := cast(^Data_State)scene.state // set by data_load; nil when the scene was not loaded async
	if state == nil {
		state = new(Data_State)
		if !scene_file_load(&state.file, scene.definition) {
			free(state)
			return false
		}
	}
	state.mtime, _ = os.last_write_time_by_name(scene.definition)
	state.ctrl = input.button(&ctx.input, "data.ctrl", .LCTRL, "Hold with S to save")
	input.bind_key(&ctx.input, state.ctrl, .RCTRL)
	state.save = input.button(&ctx.input, "data.save", .S, "Save scene data")
	scene.state = state
	data_set_name(scene, state, state.file.def.name)
	state.world = world_create(&ctx.gfx)
	world_spawn_scene(&state.world, &state.file.def)
	return true
}

// Stack_Policy.Disk: the live World as a scene file.
data_suspend :: proc(scene: ^Scene, ctx: ^Context, path: string) -> bool {
	state := cast(^Data_State)scene.state
	return world_save_scene(&state.world, &state.file.def, path)
}

// Applies the suspended file to the freshly created World (entities are matched by name).
data_resume :: proc(scene: ^Scene, ctx: ^Context, path: string) -> bool {
	state := cast(^Data_State)scene.state
	file: Scene_File
	if !scene_file_load(&file, path) do return false
	defer scene_file_destroy(&file)
	return world_apply_scene(&state.world, &file.def)
}

// Scene.name is read every frame (title, stats): it must own its text, not borrow the JSON arena.
data_set_name :: proc(scene: ^Scene, state: ^Data_State, name: string) {
	if name == "" do return
	delete(state.name)
	state.name = strings.clone(name)
	scene.name = state.name
}

data_tick :: proc(scene: ^Scene, ctx: ^Context, delta_time: f32) {
	state := cast(^Data_State)scene.state
	state.poll_timer += delta_time
	if state.poll_timer >= RELOAD_INTERVAL {
		state.poll_timer = 0
		data_reload(scene, state, scene.definition)
	}
	if input.pressed(&ctx.input, state.save) && input.down(&ctx.input, state.ctrl) do data_scene_save(scene, "")
	world_update(&state.world, delta_time)
	world_render(&state.world)
}

// Reloads when the file's mtime changed. The new mtime is recorded even on failure,
// so a broken file logs once and the next save retries.
@(private)
data_reload :: proc(scene: ^Scene, state: ^Data_State, path: string) {
	mtime, err := os.last_write_time_by_name(path)
	if err != nil || mtime == state.mtime do return
	state.mtime = mtime

	file: Scene_File
	if !scene_file_load(&file, path) do return // scene_file_load already logged
	if !world_apply_scene(&state.world, &file.def) {
		scene_file_destroy(&file)
		return
	}
	data_set_name(scene, state, file.def.name)
	scene_file_destroy(&state.file)
	state.file = file
	log.infof("scene reloaded: %s", path)
}

// Writes the World to path ("" = overwrite scene.definition). Base is the file as loaded,
// so fields the World does not model (name, assets) are kept.
data_scene_save :: proc(scene: ^Scene, path := "") -> bool {
	state := cast(^Data_State)scene.state
	target := path == "" ? scene.definition : path
	if !world_save_scene(&state.world, &state.file.def, target) do return false
	log.infof("scene saved: %s", target)
	return true
}

data_destroy :: proc(scene: ^Scene, ctx: ^Context) {
	state := cast(^Data_State)scene.state
	world_destroy(&state.world)
	scene_file_destroy(&state.file)
	delete(state.name)
	free(state)
}
