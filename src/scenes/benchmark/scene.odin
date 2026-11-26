// Benchmark: N instances of each boat model plus a few huge Stanford dragons, with on-screen text
// (FPS, object count, controls) drawn through the world HUD.
// = / - add and remove instances.
package benchmark

import engine "../../engine"
import default "../../engine/default"
import input "../../engine/input"
import sea "../sea"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:log"
import "core:os"
import "core:strconv"

BENCH_STEP :: 10 // per boat model, per keypress
BENCH_PER_MODEL :: 150 // default per-model boat count; CUBES_BENCH_PER_MODEL overrides

BOAT_PATHS :: [?]string {
	"static/models/sea/boat-fan.glb",
	"static/models/sea/boat-fishing-small.glb",
	"static/models/sea/boat-house-a.glb",
	"static/models/sea/boat-house-b.glb",
	"static/models/sea/boat-house-c.glb",
	"static/models/sea/boat-house-d.glb",
	"static/models/sea/boat-row-large.glb",
	"static/models/sea/boat-row-small.glb",
	"static/models/sea/boat-sail-a.glb",
	"static/models/sea/boat-sail-b.glb",
	"static/models/sea/boat-speed-a.glb",
	"static/models/sea/boat-speed-b.glb",
	"static/models/sea/boat-speed-c.glb",
	"static/models/sea/boat-speed-d.glb",
	"static/models/sea/boat-speed-e.glb",
	"static/models/sea/boat-speed-f.glb",
	"static/models/sea/boat-speed-g.glb",
	"static/models/sea/boat-speed-h.glb",
	"static/models/sea/boat-speed-i.glb",
	"static/models/sea/boat-speed-j.glb",
	"static/models/sea/boat-tow-a.glb",
	"static/models/sea/boat-tow-b.glb",
	"static/models/sea/boat-tug-a.glb",
	"static/models/sea/boat-tug-b.glb",
	"static/models/sea/boat-tug-c.glb",
	"static/models/sea/ship-cargo-a.glb",
	"static/models/sea/ship-cargo-b.glb",
	"static/models/sea/ship-cargo-c.glb",
	"static/models/sea/ship-large.glb",
	"static/models/sea/ship-ocean-liner.glb",
	"static/models/sea/ship-ocean-liner-small.glb",
	"static/models/sea/ship-small.glb",
	"static/models/sea/ship-small-ghost.glb",
}
BOAT_COUNT :: len(BOAT_PATHS)

// Dragon mesh is ~140 units long (boats are 3-20): scaled up it towers over
// the fleet. 58k vertices each; one instanced draw for all of them.
DRAGON_PATH :: "static/models/sea/stanford_dragon_pbr.glb"
DRAGON_COUNT :: 12
DRAGON_SCALE :: 0.6
DRAGON_RING_RADIUS :: 450
FLEET_CENTER_Z :: -135 // middle of the boat spawn area in benchmark_populate

FOG_VIEW_DISTANCE :: 700
FOG_COLOR :: [3]f32{0.671, 0.757, 0.949} // skybox horizon; matches `sky` in sea.slang
BOAT_DRAFT :: 0.1 // boat origin height above sea level at rest
FLEE_RADIUS :: 40
FLEE_TURN_RATE :: 1.5 // rad/s
SAIL_X_LIMIT :: 700 // boats wrap across x in [-SAIL_X_LIMIT, SAIL_X_LIMIT]
SAIL_Z_NEAR :: -20 // and across z in [SAIL_Z_FAR, SAIL_Z_NEAR]
SAIL_Z_FAR :: -650
BOAT_LUA_PATH :: "src/scenes/benchmark/boat.lua"
BOAT_LUA_BATCH_PATH :: "src/scenes/benchmark/boat_batch.lua"

// Rest position in x/z; tick sets its height and tilt from the sea. Heading (radians)
// drives sailing; yaw is rebuilt from it.
Boat_Slot :: struct {
	ship:    ^Ship,
	x, z:    f32,
	heading: f32,
	speed:   f32, // units/s
	yaw:     linalg.Quaternionf32,
	scale:   f32,
}

// Initial state for the Lua boats, read with a:prop("Boat"). Same values as the Boat_Slot they mirror.
Boat :: struct {
	heading, speed: f32,
}

// One actor per boat. boat is the Lua prop; it is unregistered and inert on the Odin path.
Ship :: struct {
	using actor:     engine.Actor,
	using transform: engine.Transform,
	using model:     engine.Model,
	boat:            Boat,
}

Dragon :: struct {
	using actor:     engine.Actor,
	using transform: engine.Transform,
	using model:     engine.Model,
}

BOAT_PROP_CDEF :: "typedef struct { float heading, speed; } Boat;"

Benchmark_State :: struct {
	world:           engine.World,
	sea_state:       sea.State,
	boats:           [dynamic]Boat_Slot,
	dragons:         [dynamic]^Dragon,
	per_model:       int,
	add_action:      input.Button_Action,
	subtract_action: input.Button_Action,
	fog_action:      input.Button_Action,
	sail_action:     input.Button_Action,
	sailing:         bool,
	script:          string, // Lua boat script; "" = Odin boats
	label:           string, // HUD line for the Lua variants
	hud_time:        f32,
	hud_frames:      int,
	hud_fps:         f32,
	hud_draws:       int,
}

benchmark_scene :: proc() -> engine.Scene {
	return {
		name = "Benchmark",
		create = benchmark_create,
		tick = benchmark_tick,
		destroy = benchmark_destroy,
	}
}

benchmark_lua_scene :: proc() -> engine.Scene {
	return {
		name = "Benchmark Lua",
		create = benchmark_lua_create,
		tick = benchmark_tick,
		destroy = benchmark_destroy,
	}
}

benchmark_lua_batch_scene :: proc() -> engine.Scene {
	return {
		name = "Benchmark Lua batch",
		create = benchmark_lua_batch_create,
		tick = benchmark_tick,
		destroy = benchmark_destroy,
	}
}

benchmark_fog :: proc() -> engine.Fog {
	return engine.Fog{color = FOG_COLOR, distance = FOG_VIEW_DISTANCE}
}

bench_per_model :: proc() -> (count: int, ok: bool) {
	text := os.get_env("CUBES_BENCH_PER_MODEL", context.temp_allocator)
	if text == "" do return BENCH_PER_MODEL, true
	n, parsed := strconv.parse_int(text)
	if !parsed || n < 0 {
		log.errorf("CUBES_BENCH_PER_MODEL: invalid per-model count %q", text)
		return 0, false
	}
	return n, true
}

benchmark_create :: proc(demo: ^engine.Scene, ctx: ^engine.Context) -> bool {
	return benchmark_setup(demo, ctx, "", "")
}

benchmark_lua_create :: proc(demo: ^engine.Scene, ctx: ^engine.Context) -> bool {
	return benchmark_setup(demo, ctx, BOAT_LUA_PATH, "lua per-actor")
}

benchmark_lua_batch_create :: proc(demo: ^engine.Scene, ctx: ^engine.Context) -> bool {
	return benchmark_setup(demo, ctx, BOAT_LUA_BATCH_PATH, "lua batch")
}

benchmark_lua_setup :: proc(world: ^engine.World) -> bool {
	engine.register_props(world, Boat)
	if !engine.script_expose(world, Boat, "Boat", BOAT_PROP_CDEF) do return false
	if !engine.script_set_config(world, "FLEE_RADIUS", FLEE_RADIUS) do return false
	if !engine.script_set_config(world, "FLEE_TURN_RATE", FLEE_TURN_RATE) do return false
	if !engine.script_set_config(world, "SAIL_X_LIMIT", SAIL_X_LIMIT) do return false
	if !engine.script_set_config(world, "SAIL_Z_NEAR", SAIL_Z_NEAR) do return false
	if !engine.script_set_config(world, "SAIL_Z_FAR", SAIL_Z_FAR) do return false
	if !engine.script_set_config(world, "BOAT_DRAFT", BOAT_DRAFT) do return false
	return true
}

benchmark_setup :: proc(demo: ^engine.Scene, ctx: ^engine.Context, script, label: string) -> bool {
	per_model, ok := bench_per_model()
	if !ok do return false
	state := new(Benchmark_State)
	demo.state = state
	state.script = script
	state.label = label
	engine.camera_fly(ctx)

	state.world = engine.world_create(&ctx.gfx)
	engine.script_bind(&state.world, &ctx.input, ctx)
	if script != "" && !benchmark_lua_setup(&state.world) {
		engine.world_destroy(&state.world)
		demo.state = nil
		free(state)
		return false
	}
	state.add_action = input.button(&ctx.input, "benchmark.add", .EQUALS, "Add actors")
	state.subtract_action = input.button(
		&ctx.input,
		"benchmark.subtract",
		.MINUS,
		"Remove actors",
	)
	state.fog_action = input.button(&ctx.input, "benchmark.fog", .V, "Toggle fog")
	state.sail_action = input.button(&ctx.input, "benchmark.sail", .B, "Toggle sailing")
	state.sailing = true

	// Uncapped: the point of this scene is measuring real frame cost. Fog on by
	// default so boats and dragons share the sea's horizon blend.
	state.world.stage = engine.Stage{skybox = default.SKYBOX_PATH, fog = benchmark_fog(), uncapped = true}
	_ = sea.add(&state.world, ctx, &state.sea_state)

	rand.reset(1) // fixed layout: every run draws the same fleet, so results compare
	benchmark_populate(state, per_model)
	return true
}

// Respawns the fleet at a new per-model instance count. Models stay loaded in
// the World's asset cache; only the actors are recreated.
benchmark_populate :: proc(state: ^Benchmark_State, per_model: int) {
	state.per_model = per_model
	for boat in state.boats do engine.world_destroy_actor(&state.world, boat.ship.id)
	clear(&state.boats)
	for dragon in state.dragons do engine.world_destroy_actor(&state.world, dragon.id)
	clear(&state.dragons)

	for path in BOAT_PATHS {
		for _ in 0 ..< per_model {
			position := engine.Vec3 {
				rand.float32_range(-700, 700),
				-0.5,
				rand.float32_range(-650, -20),
			}
			heading := rand.float32_range(0, linalg.TAU)
			yaw := linalg.quaternion_from_euler_angles_f32(0, heading, 0, .XYZ)
			scale := 0.25 + rand.float32_range(0, 0.2)
			if rand.float32() < 0.12 do scale *= rand.float32_range(2, 4) // a few big ships among the small boats
			speed := rand.float32_range(2, 6)
			ship := engine.world_add_actor(
				&state.world,
				Ship {
					actor = engine.actor_hooks(Ship, lua = state.script),
					transform = engine.transform_create(
						position = position,
						rotation = yaw,
						scale = {scale, scale, scale},
					),
					model = engine.model_create(path = path),
					boat = Boat{heading = heading, speed = speed},
				},
			)
			append(
				&state.boats,
				Boat_Slot {
					ship = ship,
					x = position.x,
					z = position.z,
					heading = heading,
					speed = speed,
					yaw = yaw,
					scale = scale,
				},
			)
		}
	}
	// Dragons ring the fleet, facing its centre, independent of the per-model count.
	for index in 0 ..< DRAGON_COUNT {
		angle := f32(index) / DRAGON_COUNT * linalg.TAU
		scale := f32(DRAGON_SCALE)
		dragon := engine.world_add_actor(
			&state.world,
			Dragon {
				transform = engine.transform_create(
					position = {
						math.cos(angle) * DRAGON_RING_RADIUS,
						0,
						FLEET_CENTER_Z + math.sin(angle) * DRAGON_RING_RADIUS,
					},
					rotation = linalg.quaternion_from_euler_angles_f32(0, -angle - linalg.PI / 2, 0, .XYZ),
					scale = {scale, scale, scale},
				),
				model = engine.model_create(path = DRAGON_PATH),
			},
		)
		append(&state.dragons, dragon)
	}
}

// Sails along heading. Within FLEE_RADIUS of the camera it turns away at FLEE_TURN_RATE
// (shortest angle) and doubles speed. Wraps across the sail box edges.
boat_step :: proc(slot: ^Boat_Slot, camera: engine.Vec3, dt: f32, sailing: bool) {
	if !sailing do return
	dx := slot.x - camera.x
	dz := slot.z - camera.z
	speed := slot.speed
	if dx * dx + dz * dz < FLEE_RADIUS * FLEE_RADIUS {
		// heading h moves along (sin h, cos h), so the away direction is atan2(dx, dz)
		diff := math.atan2(dx, dz) - slot.heading
		for diff > linalg.PI do diff -= linalg.TAU
		for diff < -linalg.PI do diff += linalg.TAU
		slot.heading += clamp(diff, -FLEE_TURN_RATE * dt, FLEE_TURN_RATE * dt)
		speed *= 2
	}
	slot.x += math.sin(slot.heading) * speed * dt
	slot.z += math.cos(slot.heading) * speed * dt
	if slot.x < -SAIL_X_LIMIT {
		slot.x = SAIL_X_LIMIT
	} else if slot.x > SAIL_X_LIMIT {
		slot.x = -SAIL_X_LIMIT
	}
	if slot.z < SAIL_Z_FAR {
		slot.z = SAIL_Z_NEAR
	} else if slot.z > SAIL_Z_NEAR {
		slot.z = SAIL_Z_FAR
	}
	slot.yaw = linalg.quaternion_from_euler_angles_f32(0, slot.heading, 0, .XYZ)
}

benchmark_tick :: proc(demo: ^engine.Scene, ctx: ^engine.Context, delta_time: f32) {
	state := cast(^Benchmark_State)demo.state

	inputs := &ctx.input
	if input.pressed(inputs, state.add_action) {
		benchmark_populate(state, state.per_model + BENCH_STEP)
	}
	if input.pressed(inputs, state.subtract_action) && state.per_model >= BENCH_STEP {
		benchmark_populate(state, state.per_model - BENCH_STEP)
	}
	if input.pressed(inputs, state.fog_action) {
		if _, fog_on := state.world.stage.fog.?; fog_on {
			state.world.stage.fog = nil
		} else {
			state.world.stage.fog = benchmark_fog()
		}
	}
	if input.pressed(inputs, state.sail_action) do state.sailing = !state.sailing
	_, fog_on := state.world.stage.fog.?

	// world_update adds delta_time to world.time after this tick; Lua boats read engine.time() inside
	// that update, so this value is the one they see. Mesh, Odin boats and Lua boats share it.
	state.sea_state.time = state.world.time + delta_time
	if state.script == "" {
		camera := engine.camera_position(ctx)
		for &boat in state.boats {
			boat_step(&boat, camera, delta_time, state.sailing)
			flat := engine.Vec3{boat.x, sea.Y, boat.z}
			h, grad := sea.surface_height(flat.xz, state.sea_state.time, linalg.distance(camera, flat))
			transform := &boat.ship.transform
			transform.position = {boat.x, sea.Y + h + BOAT_DRAFT, boat.z}
			transform.rotation = sea.tilt(grad) * boat.yaw
			transform.scale = {boat.scale, boat.scale, boat.scale}
		}
	}

	// FPS and draws refresh once per second so the text stays readable.
	state.hud_time += delta_time
	state.hud_frames += 1
	if state.hud_time >= 1 || (state.hud_fps == 0 && state.hud_time > 0) {
		state.hud_fps = f32(state.hud_frames) / state.hud_time
		state.hud_draws = engine.draw_call_count(ctx)
		state.hud_time, state.hud_frames = 0, 0
	}

	// HUD text in window pixels (y down), drawn by world_render.
	fps_buffer, count_buffer, draws_buffer: [32]byte
	engine.world_text(&state.world, fmt.bprintf(fps_buffer[:], "%.0f FPS", state.hud_fps), {10, 10})
	engine.world_text(
		&state.world,
		fmt.bprintf(
			count_buffer[:],
			"objects: %d",
			state.per_model * BOAT_COUNT + DRAGON_COUNT,
		),
		{10, 30},
	)
	engine.world_text(&state.world, fmt.bprintf(draws_buffer[:], "draws: %d", state.hud_draws), {10, 50})
	engine.world_text(
		&state.world,
		"=/- objects  wasd move  shift fast  c smooth cam",
		{10, 70},
		{0.8, 0.8, 0.8, 1},
	)
	engine.world_text(
		&state.world,
		fog_on ? "fog + view distance on (V)" : "fog + view distance off (V)",
		{10, 90},
	)
	engine.world_text(
		&state.world,
		state.sailing ? "sailing on (B)" : "sailing off (B)",
		{10, 110},
	)
	if state.label != "" do engine.world_text(&state.world, state.label, {10, 130})

	engine.world_update(&state.world, delta_time)
	engine.world_render(&state.world, ctx.blend)
}

benchmark_destroy :: proc(demo: ^engine.Scene, ctx: ^engine.Context) {
	state := cast(^Benchmark_State)demo.state
	engine.world_destroy(&state.world)
	sea.destroy(ctx, &state.sea_state)
	delete(state.boats)
	delete(state.dragons)
	free(state)
}
