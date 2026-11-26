// Enemy ship: spawns on a ring around the player and chases it. Built with
// engine.world_add_actor; see game_player.odin for the per-actor convention.
package game

import engine "../../engine"
import "core:math"
import "core:math/linalg"
import "core:math/rand"

ENEMY_MODEL :: "static/models/sea/ship-large.glb"
ENEMY_SCALE :: 0.02
ENEMY_SPEED :: 1.2
ENEMY_RING :: 9 // spawn distance from the player
ENEMY_HIT_RADIUS :: 1.2
ENEMY_HIT_DAMAGE :: 25
ENEMY_SCRIPT :: "src/scenes/game/enemy.lua" // chase, contact and damage; constants pushed by game_create

Enemy :: struct {
	using actor:     engine.Actor,
	using transform: engine.Transform,
	using model:     engine.Model,
}

// Spawns on the ring around the player, facing it.
enemy_spawn :: proc(world: ^engine.World) {
	player := engine.world_find(world, Player)
	angle := rand.float32_range(0, linalg.TAU)
	offset := engine.Vec3{math.cos(angle), 0, math.sin(angle)} * ENEMY_RING
	engine.world_add_actor(
		world,
		Enemy {
			actor = engine.actor_hooks(Enemy, lua = ENEMY_SCRIPT),
			transform = engine.transform_create(
				position = player.position + offset,
				rotation = game_facing(-offset),
				scale = {ENEMY_SCALE, ENEMY_SCALE, ENEMY_SCALE},
			),
			model = engine.model_create(path = ENEMY_MODEL),
		},
	)
}

// Destroys every live Enemy; the player's respawn clears the field.
enemy_destroy_all :: proc(world: ^engine.World) {
	for id in engine.world_actors(world) {
		if engine.world_get(world, id, Enemy) != nil do engine.world_destroy_actor(world, id)
	}
}
