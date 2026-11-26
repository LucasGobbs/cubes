// Per-actor convention: a struct with `using actor: engine.Actor` first, its Props as
// fields, built by a spawn proc through engine.world_add_actor. Hooks take self only.
// Player is a CesiumMan steered on the XZ plane; enemy chases it. See game_enemy.odin.
package game

import engine "../../engine"
import "core:log"
import "core:math"
import "core:math/linalg"

PLAYER_MODEL :: "static/models/rigged_cesiumman.glb"
PLAYER_CLIP :: "clip_0"
PLAYER_SPEED :: 3
PLAYER_HEALTH :: 100
PLAYER_AUTOPILOT_IDLE :: 3 // seconds without input before the player circles
PLAYER_AUTOPILOT_TURN :: 0.8 // rad/s of the circle's heading

Player :: struct {
	using actor:     engine.Actor,
	using transform: engine.Transform,
	using model:     engine.Model, // before animator: the Animator needs the skinned Model
	animator:        engine.Animator,
	health:          engine.Health,
	name:            engine.Name, // lets enemy.lua find the player with engine.find("player")
	wish_dir:        engine.Vec3, // zero means no input; the scene's fixed_tick writes it each step
	idle:            f32, // seconds since last input
	heading:         f32, // heading of the autopilot circle
}

player_spawn :: proc(world: ^engine.World) {
	engine.world_add_actor(
		world,
		Player {
			actor = engine.actor_hooks(Player, tick = player_tick),
			transform = engine.transform_create(),
			model = engine.model_create(path = PLAYER_MODEL),
			animator = engine.Animator{clip = PLAYER_CLIP},
			name = engine.Name{value = "player"},
			health = engine.Health{current = PLAYER_HEALTH, max = PLAYER_HEALTH},
		},
	)
}

player_tick :: proc(self: ^Player, dt: f32) {
	move := self.wish_dir
	if move == {} {
		self.idle += dt
	} else {
		self.idle = 0
	}
	if self.idle > PLAYER_AUTOPILOT_IDLE {
		self.heading += PLAYER_AUTOPILOT_TURN * dt
		move = {math.cos(self.heading), 0, math.sin(self.heading)}
	}
	if move != {} {
		direction := linalg.normalize(move)
		self.position += direction * PLAYER_SPEED * dt
		self.rotation = game_facing(direction)
	}

	if self.health.current > 0 do return
	log.infof("game: player down, respawning at origin")
	enemy_destroy_all(self.world)
	self.position = {}
	self.rotation = linalg.QUATERNIONF32_IDENTITY
	self.health.current = self.health.max
}
