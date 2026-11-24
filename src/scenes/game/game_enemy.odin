// Enemy ship: spawns on a ring around the player and chases it. Registered with
// engine.register_type; see game_player.odin for the per-actor convention.
package game

import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import engine "../../engine"

ENEMY_MODEL :: "static/models/sea/ship-large.glb"
ENEMY_SCALE :: 0.02
ENEMY_SPEED :: 1.2
ENEMY_RING :: 9 // spawn distance from the player
ENEMY_HIT_RADIUS :: 1.2
ENEMY_HIT_DAMAGE :: 25

Enemy :: struct {
	player: engine.Actor_Type, // finds the target player
}

// Spawns on the ring around the player, facing it.
enemy_create :: proc(world: ^engine.World, id: engine.Actor_Id, self: ^Enemy) {
	player_id, _ := engine.world_find_state(world, self.player, Player)
	player_position := engine.actor_props(world, player_id, engine.Transform).position
	angle := rand.float32_range(0, linalg.TAU)
	offset := engine.Vec3{math.cos(angle), 0, math.sin(angle)} * ENEMY_RING
	engine.actor_add_props(world, id, engine.Model{path = ENEMY_MODEL})
	engine.actor_set_transform(
		world,
		id,
		position = player_position + offset,
		rotation = game_facing(-offset),
		scale = {ENEMY_SCALE, ENEMY_SCALE, ENEMY_SCALE},
	)
}

// Chases the player on the XZ plane. On contact the enemy destroys itself, which
// frees self: nothing may touch self after world_destroy_actor.
enemy_tick :: proc(world: ^engine.World, id: engine.Actor_Id, self: ^Enemy, dt: f32) {
	player_id, _ := engine.world_find_state(world, self.player, Player)
	target := engine.actor_props(world, player_id, engine.Transform).position
	transform := engine.actor_props(world, id, engine.Transform)
	to_target := target - transform.position
	to_target.y = 0
	transform.position += linalg.normalize0(to_target) * ENEMY_SPEED * dt
	transform.rotation = game_facing(to_target)
	if linalg.length(transform.position - target) >= ENEMY_HIT_RADIUS do return

	engine.world_destroy_actor(world, id)
	health := engine.actor_props(world, player_id, engine.Health)
	health.current -= ENEMY_HIT_DAMAGE
	log.infof("game: enemy destroyed, health %.0f/%.0f", health.current, health.max)
}
