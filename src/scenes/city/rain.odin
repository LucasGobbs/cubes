// Rain: two GPU particle layers in wrap mode (Emitter_Desc.wrap_box). Drops are fixed in a box centred on the camera and
// folded inside it by the render shader, so the volume follows the viewer with no emitter, nothing spawns, and no drop
// can be outrun. Drops are velocity-aligned streaks (Emitter_Desc.stretch), additive and very faint blue-white, and
// stop at the ground (floor_y). A small dense layer carries the nearby rain and a big sparse layer fills the distance.
package city

import engine "../../engine"
import gfx "../../engine/gfx"

RAIN_WIND :: gfx.Vec3{0.12, -1, 0.05} // fall direction; the slant makes drops read as wind-driven
RAIN_SPEED :: [2]f32{62, 78} // fall speed, units/s

Rain_Layer :: struct {
	side:    f32, // edge of the wrap box centred on the camera, world units
	density: f32, // drops per unit^3 at intensity 1; the count follows from side
	stretch: f32, // s of travel drawn as streak length; far drops are longer so they stay visible
	alpha:   f32,
}

RAIN_LAYERS := [2]Rain_Layer {
	{side = 180, density = 1.5e-3, stretch = 0.03, alpha = 0.1},
	{side = 520, density = 4.0e-5, stretch = 0.12, alpha = 0.05},
}

rain_spawn :: proc(state: ^City_State) {
	for layer, i in RAIN_LAYERS {
		state.rain[i] = engine.world_add_actor(
			&state.world,
			Rain_Emitter {
				transform = engine.transform_create(),
				emitter = engine.Particle_Emitter {
					mode = .GPU,
					blend = .Additive,
					capacity = u32(layer.density * layer.side * layer.side * layer.side),
					wrap_box = gfx.Vec3{layer.side, layer.side, layer.side},
					floor_y = GROUND_Y,
					direction = RAIN_WIND,
					speed = RAIN_SPEED,
					size = {0.03, 0.03},
					color_start = {0.55, 0.65, 0.85, layer.alpha},
					stretch = layer.stretch,
				},
			},
		)
	}
}

// Stops or resumes the rain; while off nothing is drawn.
rain_set :: proc(state: ^City_State, on: bool) {
	state.rain_on = on
	for r in state.rain {
		if emitter := engine.actor_emitter(&state.world, r.id); emitter != nil do emitter.active = on
	}
}

// Rain density, 0..1 (1 = the default look). Lower intensity draws a prefix of each layer's fixed drops.
rain_set_intensity :: proc(state: ^City_State, intensity: f32) {
	for r in state.rain {
		if emitter := engine.actor_emitter(&state.world, r.id); emitter != nil do emitter.intensity = intensity
	}
}
