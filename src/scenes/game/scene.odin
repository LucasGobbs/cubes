// Game: a CesiumMan player steered on the XZ plane with WASD, chased by ship
// enemies that spawn on a ring around it. All game state lives in engine.World as
// actor structs; the scene keeps only input and timers and reads input in fixed_tick.
// Idle for 3 s and the player circles on its own, so a screenshot shows hits without
// input. Per-actor logic lives in game_player.odin and game_enemy.odin.
package game

import engine "../../engine"
import input "../../engine/input"
import "core:log"
import "core:math"
import "core:math/linalg"

GAME_ENEMY_MAX :: 5
GAME_SPAWN_INTERVAL :: 2 // seconds

Game_State :: struct {
	world:       engine.World,
	move:        input.Axis_2D_Action,
	spawn_timer: f32,
	log_timer:   f32,
}

game_scene :: proc() -> engine.Scene {
	return {
		name = "Game",
		create = game_create,
		tick = game_tick,
		fixed_tick = game_fixed_tick,
		destroy = game_destroy,
	}
}

game_create :: proc(demo: ^engine.Scene, ctx: ^engine.Context) -> bool {
	gfx_ctx := &ctx.gfx
	state := new(Game_State)
	demo.state = state

	state.move = input.move_2d(
		&ctx.input,
		"game.move",
		up = .W,
		down = .S,
		left = .A,
		right = .D,
		description = "Move player",
	)

	state.world = engine.world_create(gfx_ctx)
	engine.spawn_camera(&state.world, {0, 6, 8})
	// Player spawns before any enemy: its slot ticks first, so enemies chase this frame's position.
	player_spawn(&state.world)
	return true
}

game_tick :: proc(demo: ^engine.Scene, ctx: ^engine.Context, delta_time: f32) {
	state := cast(^Game_State)demo.state
	engine.world_render(&state.world)
}

// Gameplay runs at the fixed rate (Config.fixed_hz); the frame only renders.
game_fixed_tick :: proc(demo: ^engine.Scene, ctx: ^engine.Context, delta_time: f32) {
	state := cast(^Game_State)demo.state
	v := input.axis_2d(&ctx.input, state.move)
	player := engine.world_find(&state.world, Player)
	player.wish_dir = {v.x, 0, -v.y} // W = -Z, as before

	state.spawn_timer += delta_time
	if state.spawn_timer >= GAME_SPAWN_INTERVAL {
		state.spawn_timer = 0
		if engine.world_count(&state.world, Enemy) < GAME_ENEMY_MAX {
			enemy_spawn(&state.world)
			log.infof("game: enemy spawned, %d alive", engine.world_count(&state.world, Enemy))
		}
	}

	state.log_timer += delta_time
	if state.log_timer >= 1 {
		state.log_timer = 0
		log.infof(
			"game: health %.0f/%.0f, enemies %d",
			player.health.current,
			player.health.max,
			engine.world_count(&state.world, Enemy),
		)
	}

	engine.world_update(&state.world, delta_time)
}

game_destroy :: proc(demo: ^engine.Scene, ctx: ^engine.Context) {
	state := cast(^Game_State)demo.state
	engine.world_destroy(&state.world)
	free(state)
}

// Turns the model's +Z toward the XZ direction (same convention as the benchmark dragons).
game_facing :: proc(direction: engine.Vec3) -> linalg.Quaternionf32 {
	return linalg.quaternion_from_euler_angles_f32(
		0,
		math.atan2(direction.x, direction.z),
		0,
		.XYZ,
	)
}
