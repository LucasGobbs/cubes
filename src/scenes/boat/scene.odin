// Boat: one fishing boat sails a slow circle on the displaced sea. The hull rides
// the same wave height the shader displaces; chimney smoke and stern foam are particles.
package boat

import "core:math"
import "core:math/linalg"
import gfx "../../engine/gfx"
import default "../../engine/default"
import particles "../../engine/particles"
import sea "../sea"
import engine "../../engine"

BOAT_PATH :: "static/models/sea/boat-fishing-small.glb"
BOAT_SCALE :: 1.0
BOAT_DRAFT :: 0.1 // hull origin height above sea level at rest
ORBIT_RADIUS :: 25
ORBIT_SPEED :: 0.05 // radians per second
FOG_VIEW_DISTANCE :: 700

// Boat-local points before scale/tilt/yaw; model forward assumed +X.
STERN :: [3]f32{-1.5, 0.3, 0}
CHIMNEY :: [3]f32{0.4, 1.4, 0}
BOW :: [3]f32{1.6, 0.2, 0}
FIREWORK_PERIOD :: 2.5

Boat_State :: struct {
	sea_state:    sea.State,
	sea_pipeline: gfx.Pipeline_Handle,
	sea_material: gfx.Material,
	boat:         int, // draw index
	system:       ^particles.System,
	smoke:        particles.Emitter_Handle,
	foam:         particles.Emitter_Handle,
	embers:       particles.Emitter_Handle,
	spray:        particles.Emitter_Handle,
	rain:         particles.Emitter_Handle,
	firework:     particles.Emitter_Handle,
	firework_timer, firework_hue: f32,
	angle:        f32, // orbit angle
}

boat_scene :: proc() -> engine.Scene {
	return {name = "Boat", create = boat_create, tick = boat_tick, destroy = boat_destroy}
}

boat_create :: proc(demo: ^engine.Scene, ctx: ^engine.Context) -> bool {
	gfx_ctx := &ctx.gfx
	state := new(Boat_State)
	demo.state = state
	engine.camera_fly(ctx)

	gfx.skybox_add(gfx_ctx, default.SKYBOX_PATH)
	state.sea_pipeline = sea.pipeline_create(gfx_ctx, &state.sea_state)
	state.sea_material = gfx.material_make(state.sea_pipeline)
	gfx.draw_create(gfx_ctx, {mesh = sea.mesh_data(), material = &state.sea_material})

	model := gfx.model_add(gfx_ctx, {path = BOAT_PATH, kind = .Textured_Instanced})
	state.boat = gfx.draw_create(gfx_ctx, {mesh = model})

	state.system = particles.system_create(&gfx_ctx.renderer)
	// Grey smoke rising from the chimney, drifting downwind (+X).
	state.smoke = particles.emitter_add(state.system, {
		mode        = .GPU,
		blend       = .Alpha,
		capacity    = 2048,
		rate        = 30,
		direction   = {0, 1, 0},
		spread      = 0.15,
		lifetime    = {3, 5},
		speed       = {0.6, 1.0},
		gravity     = {0.2, 0.2, 0},
		drag        = 0.3,
		size        = {0.3, 2.0},
		color_start = {0.6, 0.6, 0.6, 0.6},
		color_end   = {0.35, 0.35, 0.35, 0},
		fade_in     = 0.2,
	})
	// White foam wake behind the stern; low speed, wide spread, stays near the water.
	state.foam = particles.emitter_add(state.system, {
		mode        = .CPU,
		blend       = .Alpha,
		capacity    = 1024,
		rate        = 60,
		direction   = {0, 0, 1}, // overwritten each tick to point astern
		spread      = 0.9,
		radius      = 0.4,
		lifetime    = {1.2, 2.2},
		speed       = {0.3, 1.2},
		drag        = 1.5,
		size        = {0.4, 1.6},
		color_start = {1, 1, 1, 0.8},
		color_end   = {1, 1, 1, 0},
	})
	// Sparks popping out of the chimney; additive so they glow against the smoke.
	state.embers = particles.emitter_add(state.system, {
		mode        = .GPU,
		blend       = .Additive,
		capacity    = 1024,
		rate        = 25,
		direction   = {0, 1, 0},
		spread      = 0.5,
		radius      = 0.05,
		lifetime    = {0.8, 1.6},
		speed       = {1.5, 3},
		gravity     = {0.3, -3, 0},
		drag        = 0.4,
		size        = {0.08, 0.02},
		color_start = {1, 0.55, 0.15, 1},
		color_end   = {1, 0.1, 0, 0},
	})
	// Bright spray thrown up by the bow.
	state.spray = particles.emitter_add(state.system, {
		mode        = .GPU,
		blend       = .Additive,
		capacity    = 2048,
		rate        = 120,
		direction   = {0, 1, 0},
		spread      = 0.7,
		radius      = 0.3,
		lifetime    = {0.6, 1.2},
		speed       = {1.5, 3.5},
		gravity     = {0, -6, 0},
		drag        = 0.5,
		size        = {0.15, 0.05},
		color_start = {0.7, 0.85, 1, 0.8},
		color_end   = {0.7, 0.85, 1, 0},
	})
	// Rain around the camera: a big spawn sphere above the viewer falling fast.
	state.rain = particles.emitter_add(state.system, {
		mode        = .GPU,
		blend       = .Alpha,
		capacity    = 8192,
		rate        = 3500,
		direction   = {0, -1, 0},
		spread      = 0.05,
		radius      = 25,
		lifetime    = {1.2, 1.8},
		speed       = {14, 18},
		size        = {0.06, 0.06},
		color_start = {0.75, 0.82, 0.95, 0.5},
		color_end   = {0.75, 0.82, 0.95, 0.3},
	})
	// Firework shell: no continuous rate, bursts from boat_tick.
	state.firework = particles.emitter_add(state.system, {
		mode        = .GPU,
		blend       = .Additive,
		capacity    = 2048,
		position    = {-10, 45, -40},
		direction   = {0, 1, 0},
		spread      = math.PI,
		lifetime    = {1.5, 2.5},
		speed       = {6, 14},
		gravity     = {0, -4, 0},
		drag        = 1.2,
		size        = {0.5, 0.1},
		color_start = {1, 0.5, 0.2, 1},
		color_end   = {1, 0.2, 0, 0},
	})
	return true
}

boat_tick :: proc(demo: ^engine.Scene, ctx: ^engine.Context, delta_time: f32) {
	gfx_ctx := &ctx.gfx
	state := cast(^Boat_State)demo.state

	fog_rgb := gfx.color_srgb_to_linear({0.671, 0.757, 0.949, 1}) // skybox horizon; matches `sky` in sea.slang
	gfx_ctx.renderer.fog = {fog_rgb.r, fog_rgb.g, fog_rgb.b, FOG_VIEW_DISTANCE}

	state.sea_state.time += delta_time
	state.angle += ORBIT_SPEED * delta_time
	camera := gfx_ctx.renderer.camera.position

	// Circle tangent is (-sin, 0, cos); yaw of -angle - PI/2 turns model +X onto it.
	yaw := linalg.quaternion_angle_axis_f32(-state.angle - linalg.PI / 2, {0, 1, 0})
	flat := gfx.Vec3{ORBIT_RADIUS * math.cos(state.angle), sea.Y, ORBIT_RADIUS * math.sin(state.angle)}
	h, grad := sea.surface_height(flat.xz, state.sea_state.time, linalg.distance(camera, flat))
	orientation := sea.tilt(grad) * yaw
	origin := gfx.Vec3{flat.x, sea.Y + h + BOAT_DRAFT, flat.z}
	gfx.draw_move(gfx_ctx, state.boat, origin, orientation, {BOAT_SCALE, BOAT_SCALE, BOAT_SCALE})

	chimney := origin + linalg.quaternion_mul_vector3(orientation, CHIMNEY * BOAT_SCALE)
	stern := origin + linalg.quaternion_mul_vector3(orientation, STERN * BOAT_SCALE)
	stern_h, _ := sea.surface_height(stern.xz, state.sea_state.time, linalg.distance(camera, stern))
	astern := linalg.quaternion_mul_vector3(yaw, gfx.Vec3{-1, 0, 0})

	smoke := particles.emitter_get(state.system, state.smoke)
	smoke.desc.position = chimney
	foam := particles.emitter_get(state.system, state.foam)
	foam.desc.position = {stern.x, sea.Y + stern_h + 0.05, stern.z}
	foam.desc.direction = {astern.x, 0, astern.z}

	embers := particles.emitter_get(state.system, state.embers)
	embers.desc.position = chimney
	bow := origin + linalg.quaternion_mul_vector3(orientation, BOW * BOAT_SCALE)
	bow_h, _ := sea.surface_height(bow.xz, state.sea_state.time, linalg.distance(camera, bow))
	spray := particles.emitter_get(state.system, state.spray)
	spray.desc.position = {bow.x, sea.Y + bow_h, bow.z}
	rain := particles.emitter_get(state.system, state.rain)
	rain.desc.position = camera + {0, 14, 0} // box of rain follows the viewer

	// Firework: a new color and burst every few seconds, anchored in the world.
	state.firework_timer -= delta_time
	if state.firework_timer <= 0 {
		state.firework_timer = FIREWORK_PERIOD
		fw := particles.emitter_get(state.system, state.firework)
		hue := state.firework_hue
		state.firework_hue += 0.37
		hue -= math.floor(hue)
		fw.desc.color_start = {0.5 + 0.5 * math.cos(2 * math.PI * hue), 0.5 + 0.5 * math.cos(2 * math.PI * (hue + 0.33)), 0.5 + 0.5 * math.cos(2 * math.PI * (hue + 0.66)), 1}
		fw.desc.color_end = {fw.desc.color_start.r, fw.desc.color_start.g, fw.desc.color_start.b, 0}
		particles.emitter_burst(fw, 500)
	}

	particles.system_update(state.system, delta_time)
	gfx.render(gfx_ctx)
}

boat_destroy :: proc(demo: ^engine.Scene, ctx: ^engine.Context) {
	state := cast(^Boat_State)demo.state
	particles.system_destroy(state.system)
	gfx.material_destroy(&state.sea_material)
	free(state)
}
