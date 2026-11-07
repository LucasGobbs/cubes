// Per-entity convention: a state struct registered with engine.entity_register, plus
// create/tick procs. Components (Transform, Model, Health, ...) live in engine.World,
// never in the struct. Scenes only orchestrate.
// Player is a CesiumMan steered on the XZ plane; enemy chases it. See game_enemy.odin.
package main

import "core:log"
import "core:math"
import "core:math/linalg"
import engine "engine"
import gbbfx "gbbfx"

PLAYER_MODEL :: "static/models/rigged_cesiumman.glb"
PLAYER_CLIP :: "clip_0"
PLAYER_SPEED :: 3
PLAYER_HEALTH :: 100
PLAYER_AUTOPILOT_IDLE :: 3 // seconds without input before the player circles
PLAYER_AUTOPILOT_TURN :: 0.8 // rad/s of the circle's heading

Player :: struct {
	enemy:   engine.Entity_Type, // destroyed on respawn
	input:   gbbfx.Vec3, // zero move means no input; the scene writes it each frame
	idle:    f32, // seconds since last input
	heading: f32, // heading of the autopilot circle
}

player_create :: proc(world: ^engine.World, id: engine.Entity_Id, self: ^Player) {
	engine.world_add(world, id, engine.Model{path = PLAYER_MODEL})
	engine.world_add(world, id, engine.Animator{clip = PLAYER_CLIP})
	engine.world_add(world, id, engine.Health{current = PLAYER_HEALTH, max = PLAYER_HEALTH})
}

player_tick :: proc(world: ^engine.World, id: engine.Entity_Id, self: ^Player, dt: f32) {
	move := self.input
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
		transform := engine.world_get(world, id, engine.Transform)
		transform.position += direction * PLAYER_SPEED * dt
		transform.rotation = game_facing(direction)
	}

	health := engine.world_get(world, id, engine.Health)
	if health.current > 0 do return
	log.infof("game: player down, respawning at origin")
	engine.world_destroy_type(world, self.enemy)
	transform := engine.world_get(world, id, engine.Transform)
	transform.position = {}
	transform.rotation = linalg.QUATERNIONF32_IDENTITY
	health.current = health.max
}
