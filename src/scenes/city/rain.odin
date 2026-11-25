// Rain: one GPU particle emitter that rides along with the camera, so only the volume around the viewer is
// simulated (no city-sized emitter). New drops spawn in a sphere centred on the camera each frame; drops already in
// flight keep their world position and fall out of view behind a moving camera. Drops are velocity-aligned streaks
// (Emitter_Desc.stretch), additive and faint blue-white.
package city

import engine "../../engine"
import gfx "../../engine/gfx"
import "core:math/linalg"

RAIN_CAPACITY :: 32768
RAIN_RADIUS :: 90 // spawn sphere around the camera, world units
RAIN_LIFT :: 25 // the sphere sits this far above the camera: drops spend more of their fall in view
RAIN_SPEED :: [2]f32{62, 78} // fall speed, units/s
RAIN_LIFETIME :: [2]f32{1.4, 1.8} // fall of about 90..140 units, longer than the radius so drops cross the camera
RAIN_RATE :: 19000 // drops/s: about capacity / mean lifetime, so the ring stays full without overwriting live drops
RAIN_STRETCH :: 0.035 // s of travel drawn as streak length (about 2.5 units)
RAIN_WIND :: gfx.Vec3{0.12, -1, 0.05} // fall direction; the slant makes drops read as wind-driven

rain_spawn :: proc(state: ^City_State) {
	state.rain = engine.spawn(
		&state.world,
		engine.Particle_Emitter {
			mode = .GPU,
			blend = .Additive,
			capacity = RAIN_CAPACITY,
			rate = RAIN_RATE,
			direction = RAIN_WIND,
			spread = 0.03,
			radius = RAIN_RADIUS,
			lifetime = RAIN_LIFETIME,
			speed = RAIN_SPEED,
			size = {0.03, 0.03},
			color_start = {0.55, 0.65, 0.85, 0.26},
			color_end = {0.55, 0.65, 0.85, 0},
			fade_in = 0.12, // drops fade in instead of popping into the sphere
			stretch = RAIN_STRETCH,
		},
		engine.Transform{scale = {1, 1, 1}, rotation = linalg.QUATERNIONF32_IDENTITY},
	)
}

// Moves the emitter to the camera. The engine copies the actor Transform to the emitter in world_update, so call
// this before it.
rain_follow_camera :: proc(state: ^City_State, ctx: ^engine.Context) {
	cam := gfx.camera(&ctx.gfx).position
	engine.actor_set_transform(&state.world, state.rain, position = cam + {0, RAIN_LIFT, 0})
}

// Stops or resumes spawning; drops already falling finish their fall.
rain_set :: proc(state: ^City_State, on: bool) {
	state.rain_on = on
	if emitter := engine.actor_emitter(&state.world, state.rain); emitter != nil do emitter.active = on
}
