package benchmark

import engine "../../engine"
import "../../engine/input"
import mock "../../engine/input/adapters/mock"
import sea "../sea"
import "core:math"
import "core:sync"
import "core:testing"

// Serialises the tests in this file that create a script host. The engine package guards its own
// host tests with script_api_lock, which is unexported; this package has its own lock.
@(private = "file")
parity_lock: sync.Mutex

PARITY_BOATS :: 20
PARITY_TICKS :: 120
PARITY_DT :: 1.0 / 60
// Odin math is f32, LuaJIT math is f64: positions drift by f32 rounding over the ticks, so the
// bound is absolute plus relative (about 1e-5 of the coordinate). A logic bug shows up at units, not here.
PARITY_ABS :: 1e-3
PARITY_REL :: 1e-5

parity_close :: proc(got, want: f32) -> bool {
	return math.abs(f64(got) - f64(want)) <= PARITY_ABS + PARITY_REL * math.abs(f64(want))
}

// Even indices start inside FLEE_RADIUS of the camera at the origin (they flee); odd ones sail far away.
parity_boat_pose :: proc(i: int) -> (x, z, heading, speed: f32) {
	if i % 2 == 0 {
		x = f32(i) - 10
		z = -15 - f32(i) * 0.5
	} else {
		x = -600 + f32(i) * 50
		z = -300 - f32(i) * 10
	}
	heading = f32(i) * 0.37 - 2
	speed = 2 + f32(i % 5)
	return
}

// Odin boat_step and the Lua boat.lua must agree on x/z after the same ticks. Heading is not compared
// directly; it is observable only through x/z, which move with it.
@(test)
test_boat_lua_matches_odin_step :: proc(t: ^testing.T) {
	sync.guard(&parity_lock)
	inputs := input.system_create(mock.create())
	defer input.system_destroy(&inputs)
	world := engine.world_create(nil)
	defer engine.world_destroy(&world)
	engine.script_bind(&world, &inputs)
	if !testing.expect(t, benchmark_lua_setup(&world), "benchmark_lua_setup failed") do return

	slots: [PARITY_BOATS]Boat_Slot
	ids: [PARITY_BOATS]engine.Actor_Id
	for i in 0 ..< PARITY_BOATS {
		x, z, heading, speed := parity_boat_pose(i)
		slots[i] = Boat_Slot{x = x, z = z, heading = heading, speed = speed}
		ids[i] = engine.spawn(
			&world,
			engine.Transform{position = {x, -0.5, z}, scale = {1, 1, 1}},
			engine.Script{path = BOAT_LUA_PATH},
			Boat{heading = heading, speed = speed},
		)
	}

	for _ in 0 ..< PARITY_TICKS {
		for &slot in slots do boat_step(&slot, engine.Vec3{}, PARITY_DT, true)
		engine.world_update(&world, PARITY_DT)
	}

	for i in 0 ..< PARITY_BOATS {
		tf := engine.actor_transform(&world, ids[i])
		testing.expectf(
			t,
			parity_close(tf.position.x, slots[i].x),
			"boat %d x: lua %v odin %v",
			i,
			tf.position.x,
			slots[i].x,
		)
		testing.expectf(
			t,
			parity_close(tf.position.z, slots[i].z),
			"boat %d z: lua %v odin %v",
			i,
			tf.position.z,
			slots[i].z,
		)
	}
}

// A Lua boat spawned mid-run must ride the same wave as the mesh: y = sea.Y + surface height + draft,
// with the height taken at world.time (the scene clock), not at a per-actor clock starting at 0.
@(test)
test_boat_lua_sea_phase_matches_scene_clock :: proc(t: ^testing.T) {
	sync.guard(&parity_lock)
	inputs := input.system_create(mock.create())
	defer input.system_destroy(&inputs)
	world := engine.world_create(nil)
	defer engine.world_destroy(&world)
	engine.script_bind(&world, &inputs)
	if !testing.expect(t, benchmark_lua_setup(&world), "benchmark_lua_setup failed") do return

	for _ in 0 ..< 37 do engine.world_update(&world, PARITY_DT)
	id := engine.spawn(
		&world,
		engine.Transform{position = {-100, -0.5, -200}, scale = {1, 1, 1}},
		engine.Script{path = BOAT_LUA_PATH},
		Boat{heading = 0.5, speed = 3},
	)
	engine.world_update(&world, PARITY_DT)

	tf := engine.actor_transform(&world, id)
	x, z := tf.position.x, tf.position.z
	dist := math.sqrt(x * x + sea.Y * sea.Y + z * z)
	h, _ := sea.surface_height({x, z}, world.time, dist)
	want := sea.Y + h + BOAT_DRAFT
	testing.expectf(
		t,
		parity_close(tf.position.y, want),
		"sea phase: y %v want %v at world.time %v",
		tf.position.y,
		want,
		world.time,
	)
}
