// Game: a CesiumMan player steered on the XZ plane with WASD, chased by ship
// enemies that spawn on a ring around it. All game state lives in engine.World;
// the scene keeps only the entity types it registered and writes player input.
// Idle for 3 s and the player circles on its own, so a screenshot shows hits without
// input. Per-entity logic lives in game_player.odin and game_enemy.odin.
package game

import engine "../../engine"
import gfx "../../engine/gfx"
import input "../../engine/input"
import "core:log"
import "core:math"
import "core:math/linalg"

GAME_ENEMY_MAX :: 5
GAME_SPAWN_INTERVAL :: 2 // seconds

Game_State :: struct {
	world:       engine.World,
	player_type: engine.Entity_Type,
	enemy_type:  engine.Entity_Type,
	keys:        [4]input.Button_Action, // up, down, left, right
	spawn_timer: f32,
	log_timer:   f32,
}

game_scene :: proc() -> engine.Scene {
	return {name = "Game", create = game_create, tick = game_tick, destroy = game_destroy}
}

game_create :: proc(demo: ^engine.Scene, dev: ^gfx.Device) -> bool {
	state := new(Game_State)
	demo.state = state
	engine.scene_camera_reset(demo, dev) // restores full-window targets after the editor shrinks them

	inputs := gfx.gfx_input(dev)
	state.keys = {
		input.button(inputs, "game.up"),
		input.button(inputs, "game.down"),
		input.button(inputs, "game.left"),
		input.button(inputs, "game.right"),
	}
	input.bind_key(inputs, state.keys[0], .W)
	input.bind_key(inputs, state.keys[1], .S)
	input.bind_key(inputs, state.keys[2], .A)
	input.bind_key(inputs, state.keys[3], .D)

	state.world = engine.world_create(dev)
	// Player first: its slot ticks before enemies, so enemies chase this frame's position.
	state.player_type = engine.register_type(
		&state.world,
		Player,
		player_create,
		player_tick,
		nil,
	)
	state.enemy_type = engine.register_type(&state.world, Enemy, enemy_create, enemy_tick, nil)
	engine.spawn(
		&state.world,
		engine.Camera{look_at = gfx.Vec3{}},
		engine.Transform{position = {0, 6, 8}},
	)
	engine.spawn_typed(&state.world, state.player_type, Player{enemy = state.enemy_type})
	return true
}

game_tick :: proc(demo: ^engine.Scene, dev: ^gfx.Device, delta_time: f32) {
	state := cast(^Game_State)demo.state
	inputs := gfx.gfx_input(dev)

	move: gfx.Vec3
	if input.down(inputs, state.keys[0]) do move.z -= 1
	if input.down(inputs, state.keys[1]) do move.z += 1
	if input.down(inputs, state.keys[2]) do move.x -= 1
	if input.down(inputs, state.keys[3]) do move.x += 1
	player_id, player := engine.world_find_state(&state.world, state.player_type, Player)
	player.input = move

	state.spawn_timer += delta_time
	if state.spawn_timer >= GAME_SPAWN_INTERVAL {
		state.spawn_timer = 0
		if engine.world_count(&state.world, state.enemy_type) < GAME_ENEMY_MAX {
			engine.spawn_typed(&state.world, state.enemy_type, Enemy{player = state.player_type})
			log.infof(
				"game: enemy spawned, %d alive",
				engine.world_count(&state.world, state.enemy_type),
			)
		}
	}

	state.log_timer += delta_time
	if state.log_timer >= 1 {
		state.log_timer = 0
		health := engine.get(&state.world, player_id, engine.Health)
		log.infof(
			"game: health %.0f/%.0f, enemies %d",
			health.current,
			health.max,
			engine.world_count(&state.world, state.enemy_type),
		)
	}

	engine.world_update(&state.world, delta_time)
	engine.world_render(&state.world)
}

game_destroy :: proc(demo: ^engine.Scene, dev: ^gfx.Device) {
	state := cast(^Game_State)demo.state
	engine.world_destroy(&state.world)
	free(state)
}

// Turns the model's +Z toward the XZ direction (same convention as the benchmark dragons).
game_facing :: proc(direction: gfx.Vec3) -> linalg.Quaternionf32 {
	return linalg.quaternion_from_euler_angles_f32(
		0,
		math.atan2(direction.x, direction.z),
		0,
		.XYZ,
	)
}
