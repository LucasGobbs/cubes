// Physics: a grid of Box3D spheres dropped onto a static ground box. The physics
// world steps at the fixed rate; each frame renders the poses blended between the
// last two steps (ctx.blend), so motion is smooth at frame rate.
package physics_scene

import engine "../../engine"
import phys "../../engine/physics"

BALL_COUNT :: 20
BALL_RADIUS :: 0.5
BALL_MODEL :: "static/models/sphere.glb"
SPHERE_MODEL_RADIUS :: 1 // sphere.glb mesh spans -1..1 (diameter 2)
BALL_SCALE :: BALL_RADIUS / SPHERE_MODEL_RADIUS

Physics_Ball :: struct {
	entity: engine.Entity_Id,
	track:  phys.Tracked,
}

Physics_State :: struct {
	world:   engine.World,
	physics: phys.World,
	balls:   [dynamic]Physics_Ball,
}

physics_scene :: proc() -> engine.Scene {
	return {
		name = "Physics",
		create = physics_create,
		tick = physics_tick,
		fixed_tick = physics_fixed_tick,
		destroy = physics_destroy,
	}
}

physics_create :: proc(demo: ^engine.Scene, ctx: ^engine.Context) -> bool {
	state := new(Physics_State)
	demo.state = state

	state.world = engine.world_create(&ctx.gfx)
	state.physics = phys.create()
	_ = phys.body_ground(state.physics, {20, 0.5, 20})
	engine.spawn_camera(&state.world, {0, 6, 14}, {0, 2, 0})

	state.balls = make([dynamic]Physics_Ball, 0, BALL_COUNT)
	for i in 0 ..< BALL_COUNT {
		column := f32(i % 5) - 2
		row := f32(i / 5)
		position := [3]f32{column * 1.4, 2 + row * 2.4, (row - 1.5) * 1.4}
		body := phys.body_sphere(state.physics, position, BALL_RADIUS)
		track := phys.track(body)
		entity := engine.spawn(
			&state.world,
			engine.Model{path = BALL_MODEL},
			engine.Transform{position = position, scale = {BALL_SCALE, BALL_SCALE, BALL_SCALE}},
		)
		append(&state.balls, Physics_Ball{entity = entity, track = track})
	}
	return true
}

physics_tick :: proc(demo: ^engine.Scene, ctx: ^engine.Context, delta_time: f32) {
	state := cast(^Physics_State)demo.state
	for ball in state.balls {
		position, rotation := phys.tracked_blend(ball.track, ctx.blend)
		engine.entity_set_transform(
			&state.world,
			ball.entity,
			position = position,
			rotation = rotation,
			scale = {BALL_SCALE, BALL_SCALE, BALL_SCALE},
		)
	}
	engine.world_render(&state.world)
}

// Physics runs at the fixed rate (Config.fixed_hz); the frame only blends poses and renders.
physics_fixed_tick :: proc(demo: ^engine.Scene, ctx: ^engine.Context, delta_time: f32) {
	state := cast(^Physics_State)demo.state
	phys.step(state.physics, delta_time)
	for &ball in state.balls do phys.tracked_snapshot(&ball.track)
	engine.world_update(&state.world, delta_time)
}

physics_destroy :: proc(demo: ^engine.Scene, ctx: ^engine.Context) {
	state := cast(^Physics_State)demo.state
	phys.destroy(state.physics)
	engine.world_destroy(&state.world)
	delete(state.balls)
	free(state)
}
