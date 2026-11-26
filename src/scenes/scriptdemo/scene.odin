// Scriptdemo: a grid of actors, each driven by the Lua script src/scenes/scriptdemo/spinner.lua.
// Env: CUBES_SCRIPT_N = actor count (default 100); CUBES_SCRIPT_NOMODEL=1 spawns actors
// without Model, so a bench measures script/world cost instead of drawing ships.
package scriptdemo

import "core:log"
import "core:math"
import "core:os"
import "core:strconv"
import engine "../../engine"

SCRIPTDEMO_COUNT :: 100
SCRIPTDEMO_SPACING :: 3.0
SCRIPTDEMO_MODEL_PATH :: "static/models/sea/ship-small.glb"
SCRIPTDEMO_SCRIPT_PATH :: "src/scenes/scriptdemo/spinner.lua"
SCRIPTDEMO_BATCH_SCRIPT_PATH :: "src/scenes/scriptdemo/spinner_batch.lua"
SCRIPTDEMO_BALLS_SCRIPT_PATH :: "src/scenes/scriptdemo/balls.lua"
SCRIPTDEMO_BALLS_COUNT :: 20
SCRIPTDEMO_BALL_MODEL_PATH :: "static/models/sphere.glb" // mesh spans -1..1
SCRIPTDEMO_BALL_SCALE :: 0.5 // = ball radius; collider radius lives in balls.lua

Scriptdemo_State :: struct {
	world: engine.World,
}

Spinner :: struct {
	using actor:     engine.Actor,
	using transform: engine.Transform,
}

Ground :: struct {
	using actor:     engine.Actor,
	using transform: engine.Transform,
	collider:        engine.Collider,
}

Ball :: struct {
	using actor:     engine.Actor,
	using transform: engine.Transform,
	using model:     engine.Model,
}

scriptdemo_scene :: proc() -> engine.Scene {
	return {
		name = "Scriptdemo",
		create = scriptdemo_create,
		tick = scriptdemo_tick,
		destroy = scriptdemo_destroy,
	}
}

scriptdemo_batch_scene :: proc() -> engine.Scene {
	return {
		name = "Scriptdemo batch",
		create = scriptdemo_batch_create,
		tick = scriptdemo_tick,
		destroy = scriptdemo_destroy,
	}
}

scriptdemo_balls_scene :: proc() -> engine.Scene {
	return {
		name = "Scriptdemo balls",
		create = scriptdemo_balls_create,
		tick = scriptdemo_tick,
		destroy = scriptdemo_destroy,
	}
}

scriptdemo_create :: proc(demo: ^engine.Scene, ctx: ^engine.Context) -> bool {
	return scriptdemo_setup(demo, ctx, SCRIPTDEMO_SCRIPT_PATH)
}

scriptdemo_batch_create :: proc(demo: ^engine.Scene, ctx: ^engine.Context) -> bool {
	return scriptdemo_setup(demo, ctx, SCRIPTDEMO_BATCH_SCRIPT_PATH)
}

scriptdemo_balls_create :: proc(demo: ^engine.Scene, ctx: ^engine.Context) -> bool {
	count, ok := scriptdemo_count(SCRIPTDEMO_BALLS_COUNT)
	if !ok do return false
	state := new(Scriptdemo_State)
	demo.state = state
	state.world = engine.world_create(&ctx.gfx)
	engine.script_bind(&state.world, &ctx.input, ctx)
	engine.camera_fly(ctx, {0, 6, 14}, {0, 1, 0})
	engine.world_add_actor(&state.world, Ground{
		transform = engine.transform_create(position = {0, -1, 0}),
		collider  = engine.Collider{shape = engine.Box{half = {20, 0.5, 20}}, body = .Static},
	})
	for i in 0 ..< count {
		position := scriptdemo_position(i, count)
		position.y = 4 + f32(i % 5)
		engine.world_add_actor(&state.world, Ball{
			actor     = engine.actor_hooks(Ball, lua = SCRIPTDEMO_BALLS_SCRIPT_PATH),
			transform = engine.transform_create(position = position, scale = {SCRIPTDEMO_BALL_SCALE, SCRIPTDEMO_BALL_SCALE, SCRIPTDEMO_BALL_SCALE}),
			model     = engine.model_create(path = SCRIPTDEMO_BALL_MODEL_PATH),
		})
	}
	return true
}

// CUBES_SCRIPT_N: actor count. Bad input fails the scene load instead of silently defaulting.
scriptdemo_count :: proc(default_count := SCRIPTDEMO_COUNT) -> (count: int, ok: bool) {
	text := os.get_env("CUBES_SCRIPT_N", context.temp_allocator)
	if text == "" do return default_count, true
	n, parsed := strconv.parse_int(text)
	if !parsed || n < 1 {
		log.errorf("CUBES_SCRIPT_N: invalid actor count %q", text)
		return 0, false
	}
	return n, true
}

scriptdemo_nomodel :: proc() -> bool {
	return os.get_env("CUBES_SCRIPT_NOMODEL", context.temp_allocator) == "1"
}

// Square-ish grid centred on the origin; 100 actors give the original 10 x 10 layout.
scriptdemo_position :: proc(index, count: int) -> engine.Vec3 {
	columns := int(math.ceil(math.sqrt(f64(count))))
	rows := (count + columns - 1) / columns
	col := f32(index % columns) - f32(columns - 1) / 2
	row := f32(index / columns) - f32(rows - 1) / 2
	return {col * SCRIPTDEMO_SPACING, 0, row * SCRIPTDEMO_SPACING}
}

scriptdemo_setup :: proc(demo: ^engine.Scene, ctx: ^engine.Context, script_path: string) -> bool {
	count, ok := scriptdemo_count()
	if !ok do return false
	nomodel := scriptdemo_nomodel()
	state := new(Scriptdemo_State)
	demo.state = state
	state.world = engine.world_create(&ctx.gfx)
	engine.script_bind(&state.world, &ctx.input, ctx)
	engine.camera_fly(ctx)
	for i in 0 ..< count {
		spinner := engine.world_add_actor(&state.world, Spinner{
			actor     = engine.actor_hooks(Spinner, lua = script_path),
			transform = engine.transform_create(position = scriptdemo_position(i, count)),
		})
		if !nomodel do engine.model_set(spinner, SCRIPTDEMO_MODEL_PATH)
	}
	return true
}

scriptdemo_tick :: proc(demo: ^engine.Scene, ctx: ^engine.Context, delta_time: f32) {
	state := cast(^Scriptdemo_State)demo.state
	engine.world_update(&state.world, delta_time)
	engine.world_render(&state.world, ctx.blend)
}

scriptdemo_destroy :: proc(demo: ^engine.Scene, ctx: ^engine.Context) {
	state := cast(^Scriptdemo_State)demo.state
	engine.world_destroy(&state.world)
	free(state)
}
