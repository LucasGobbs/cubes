// Skinned: character viewer. Three Quaternius CC0 characters, each with 18 clips, crossfaded 0.25 s.
// Env (optional): CUBES_SKINNED_CHARACTER = mannequin | superhero_male | superhero_female (default superhero_male)
//                 CUBES_SKINNED_CLIP = clip name to start on (turns auto off)
//                 CUBES_SKINNED_AUTO = 0 | 1 (default 1: clips advance on their own, turntable on)
//                 CUBES_SKINNED_DISTANCE = camera distance in m (default 2.2)
//                 CUBES_SKINNED_TARGET_Y = camera target height in m (default 1.0)
package skinned

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import engine "../../engine"
import default "../../engine/default"
import gfx "../../engine/gfx"
import input "../../engine/input"
import loader "../../engine/gfx/loader"

CROSSFADE :: f32(0.25)
LOOP_DWELL :: f32(3.5) // seconds a looping clip plays before advancing (auto mode)
TURNTABLE_RATE :: f32(0.25) // rad/s while auto is on and the mouse is not dragging
GROUND_HALF :: f32(200) // 400 m square; fog hides its edge
GROUND_TILES :: f32(100) // one texture tile per 4 m
GROUND_TEXTURE :: "static/prototype_textures/Light/texture_01.png"
FOG_COLOR :: [3]f32{0.89, 0.91, 0.96} // sRGB of the skybox horizon
FOG_DISTANCE :: f32(60) // fog starts at 36 m, full at 60 m

Character_Info :: struct {
	label: string,
	path:  string,
}

CHARACTERS := [3]Character_Info{
	{"Mannequin", "static/models/mannequin.glb"},
	{"Superhero Male", "static/models/superhero_male.glb"},
	{"Superhero Female", "static/models/superhero_female.glb"},
}

Skinned_State :: struct {
	world:       engine.World,
	character:   int,
	clip:        int,
	auto:        bool,
	auto_timer:  f32,
	actor:       engine.Actor_Id,
	next_char:   input.Button_Action,
	prev_clip:   input.Button_Action,
	next_clip:   input.Button_Action,
	toggle_auto: input.Button_Action,
}

skinned_scene :: proc() -> engine.Scene {
	return {
		name = "Skinned",
		create = skinned_create,
		tick = skinned_tick,
		destroy = skinned_destroy,
	}
}

skinned_create :: proc(demo: ^engine.Scene, ctx: ^engine.Context) -> bool {
	state := new(Skinned_State)
	demo.state = state
	state.world = engine.world_create(&ctx.gfx)
	state.world.stage = engine.Stage{
		skybox = default.SKYBOX_PATH,
		grade = engine.Grade{exposure = 1, contrast = 1, saturation = 1},
		fog = engine.Fog{color = FOG_COLOR, distance = FOG_DISTANCE},
	}
	distance := env_float("CUBES_SKINNED_DISTANCE", 2.2)
	target_y := env_float("CUBES_SKINNED_TARGET_Y", 1.0)
	engine.camera_orbit(ctx, target = {0, target_y, 0}, distance = distance)

	state.next_char = input.button(&ctx.input, "skinned.character", .TAB, "Next character")
	state.prev_clip = input.button(&ctx.input, "skinned.clip_prev", .LEFT, "Previous clip")
	state.next_clip = input.button(&ctx.input, "skinned.clip_next", .RIGHT, "Next clip")
	state.toggle_auto = input.button(&ctx.input, "skinned.auto", .SPACE, "Toggle auto")

	state.character = env_character("CUBES_SKINNED_CHARACTER")
	state.auto = env_flag("CUBES_SKINNED_AUTO", true)
	if name := os.get_env("CUBES_SKINNED_CLIP", context.temp_allocator); name != "" {
		if index, ok := clip_index(state, name); ok {
			state.clip = index
			state.auto = false
		}
	}
	state.actor = spawn_character(state)

	// Flat ground quad facing +Y, CCW from above so BACK culling keeps it. Mesh is copied on add.
	h := GROUND_HALF
	t := GROUND_TILES
	n := [3]f32{0, 1, 0}
	white := [4]f32{1, 1, 1, 1}
	vertices := [4]gfx.VertexData{
		{position = {-h, 0, -h}, color = white, uv = {0, 0}, normal = n},
		{position = {-h, 0, h}, color = white, uv = {0, t}, normal = n},
		{position = {h, 0, h}, color = white, uv = {t, t}, normal = n},
		{position = {h, 0, -h}, color = white, uv = {t, 0}, normal = n},
	}
	indices := [6]u32{0, 1, 2, 0, 2, 3}
	ground := gfx.material_create(&ctx.gfx, {kind = .Textured, texture = GROUND_TEXTURE})
	engine.spawn(&state.world, engine.Raw_Draw{mesh = {vertices = vertices[:], indices = indices[:]}, material = ground})
	return true
}

skinned_tick :: proc(demo: ^engine.Scene, ctx: ^engine.Context, delta_time: f32) {
	state := cast(^Skinned_State)demo.state
	w := &state.world
	clips := clips_of(state)

	if input.pressed(&ctx.input, state.next_char) {
		state.character = (state.character + 1) % len(CHARACTERS)
		engine.world_destroy_actor(w, state.actor)
		state.clip = state.clip % len(clips_of(state))
		state.actor = spawn_character(state)
	}
	if input.pressed(&ctx.input, state.toggle_auto) do state.auto = !state.auto
	if input.pressed(&ctx.input, state.prev_clip) || input.pressed(&ctx.input, state.next_clip) {
		step := input.pressed(&ctx.input, state.next_clip) ? 1 : -1
		state.clip = (state.clip + step + len(clips)) % len(clips)
		state.auto = false
		engine.actor_play(w, state.actor, clips[state.clip].name, CROSSFADE)
	}

	if state.auto {
		state.auto_timer += delta_time
		dwell := LOOP_DWELL
		if !strings.has_suffix(clips[state.clip].name, "_Loop") {
			dwell = max(LOOP_DWELL, clips[state.clip].duration)
		}
		if state.auto_timer >= dwell {
			state.auto_timer = 0
			state.clip = (state.clip + 1) % len(clips)
			engine.actor_play(w, state.actor, clips[state.clip].name, CROSSFADE)
		}
		if !input.mouse_down(&ctx.input, .Left) {
			if orbit, ok := &ctx.camera.(engine.Camera_Orbit); ok do orbit.orbit.yaw += TURNTABLE_RATE * delta_time
		}
	}

	status := state.auto ? "auto" : "manual"
	hud := fmt.tprintf("%s  |  %s  [%d/%d]  %s", CHARACTERS[state.character].label, clips[state.clip].name, state.clip + 1, len(clips), status)
	ink := [4]f32{0.08, 0.1, 0.14, 1}
	engine.world_text(w, hud, {24, 24}, ink)
	engine.world_text(w, "Tab character   Left/Right clip   Space auto   drag orbit", {24, 52}, ink)

	engine.world_update(w, delta_time)
	engine.world_render(w, ctx.blend)
}

skinned_destroy :: proc(demo: ^engine.Scene, ctx: ^engine.Context) {
	state := cast(^Skinned_State)demo.state
	engine.world_destroy(&state.world)
	free(state)
}

// Feet at y = 0 in the GLB bind pose; characters are ~1.8 m tall.
spawn_character :: proc(state: ^Skinned_State) -> engine.Actor_Id {
	return engine.spawn(
		&state.world,
		engine.Model{path = CHARACTERS[state.character].path},
		engine.Animator{clip = clips_of(state)[state.clip].name},
		engine.Transform{},
	)
}

clips_of :: proc(state: ^Skinned_State) -> []loader.Clip {
	return engine.asset_model(&state.world, CHARACTERS[state.character].path).model.skin.clips
}

clip_index :: proc(state: ^Skinned_State, name: string) -> (int, bool) {
	for c, i in clips_of(state) do if c.name == name do return i, true
	return 0, false
}

// Accepts "superhero_male" or "Superhero Male" (case-insensitive); unknown or unset gives Superhero Male.
env_character :: proc(name: string) -> int {
	value := strings.to_lower(os.get_env(name, context.temp_allocator), context.temp_allocator)
	value, _ = strings.replace_all(value, "_", " ", context.temp_allocator)
	for c, i in CHARACTERS do if strings.to_lower(c.label, context.temp_allocator) == value do return i
	return 1
}

env_flag :: proc(name: string, fallback: bool) -> bool {
	switch os.get_env(name, context.temp_allocator) {
	case "0": return false
	case "1": return true
	}
	return fallback
}

env_float :: proc(name: string, fallback: f32) -> f32 {
	value, ok := strconv.parse_f32(os.get_env(name, context.temp_allocator))
	return ok ? value : fallback
}
