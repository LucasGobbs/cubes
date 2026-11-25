// Rain: two GPU particle emitters that ride along with the camera, so only the volume around the viewer is simulated
// (no city-sized emitter). New drops spawn in a sphere centred on the camera each frame; drops already in flight keep
// their world position and fall out of view behind a moving camera. A small dense layer carries the nearby rain and a
// big sparse layer (radius 260) fills the distance, so the camera cannot easily outrun the rain. Drops are
// velocity-aligned streaks (Emitter_Desc.stretch), additive and very faint blue-white (a subtle effect, not a downpour).
package city

import engine "../../engine"
import gfx "../../engine/gfx"
import "core:math/linalg"

RAIN_WIND :: gfx.Vec3{0.12, -1, 0.05} // fall direction; the slant makes drops read as wind-driven
RAIN_SPEED :: [2]f32{62, 78} // fall speed, units/s

Rain_Layer :: struct {
	capacity: u32,
	radius:   f32, // spawn sphere around the camera, world units
	lift:     f32, // the sphere sits this far above the camera: drops spend more of their fall in view
	lifetime: [2]f32, // long enough to fall across the sphere
	stretch:  f32, // s of travel drawn as streak length; far drops are longer so they stay visible
	alpha:    f32,
}

// rate = capacity / mean lifetime keeps each ring full without overwriting live drops.
RAIN_LAYERS := [2]Rain_Layer {
	{capacity = 6144, radius = 90, lift = 25, lifetime = {1.4, 1.8}, stretch = 0.03, alpha = 0.1},
	{capacity = 9216, radius = 260, lift = 90, lifetime = {3.0, 4.0}, stretch = 0.12, alpha = 0.05},
}

rain_spawn :: proc(state: ^City_State) {
	for layer, i in RAIN_LAYERS {
		mean_life := (layer.lifetime[0] + layer.lifetime[1]) / 2
		state.rain[i] = engine.spawn(
			&state.world,
			engine.Particle_Emitter {
				mode = .GPU,
				blend = .Additive,
				capacity = layer.capacity,
				rate = f32(layer.capacity) / mean_life,
				direction = RAIN_WIND,
				spread = 0.03,
				radius = layer.radius,
				lifetime = layer.lifetime,
				speed = RAIN_SPEED,
				size = {0.03, 0.03},
				color_start = {0.55, 0.65, 0.85, layer.alpha},
				color_end = {0.55, 0.65, 0.85, 0},
				fade_in = 0.12, // drops fade in instead of popping into the sphere
				stretch = layer.stretch,
			},
			engine.Transform{scale = {1, 1, 1}, rotation = linalg.QUATERNIONF32_IDENTITY},
		)
	}
}

// Moves the emitters to the camera. The engine copies the actor Transform to the emitter in world_update, so call
// this before it.
rain_follow_camera :: proc(state: ^City_State, ctx: ^engine.Context) {
	cam := gfx.camera(&ctx.gfx).position
	for layer, i in RAIN_LAYERS {
		engine.actor_set_transform(&state.world, state.rain[i], position = cam + {0, layer.lift, 0})
	}
}

// Stops or resumes spawning; drops already falling finish their fall.
rain_set :: proc(state: ^City_State, on: bool) {
	state.rain_on = on
	for id in state.rain {
		if emitter := engine.actor_emitter(&state.world, id); emitter != nil do emitter.active = on
	}
}
