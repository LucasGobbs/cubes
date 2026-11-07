// Postfx: the animated character with bloom, built on engine.World.
package main

import gbbfx "gbbfx"
import engine "engine"

POSTFX_MODEL_PATH :: "static/models/rigged_cesiumman.glb"

Postfx_State :: struct {
	world: engine.World,
}

postfx_demo_scene :: proc() -> Scene {
	return {name = "Postfx", create = postfx_create, tick = postfx_tick, destroy = postfx_destroy}
}

postfx_create :: proc(demo: ^Scene, gfx: ^gbbfx.Gfx) -> bool {
	state := new(Postfx_State)
	demo.state = state
	state.world = engine.world_create(gfx)
	engine.world_spawn(
		&state.world,
		engine.Camera{look_at = engine.Vec3{0, 0.8, 0}, bloom = engine.Bloom{threshold = 0.5, intensity = 1.5, radius = 12}},
		engine.Transform{position = {0, 1, 1.9}},
	)
	engine.world_spawn(&state.world, engine.Model{path = POSTFX_MODEL_PATH}, engine.Animator{clip = "clip_0"})
	return true
}

postfx_tick :: proc(demo: ^Scene, gfx: ^gbbfx.Gfx, delta_time: f32) {
	state := cast(^Postfx_State)demo.state
	engine.world_update(&state.world, delta_time)
	engine.world_render(&state.world)
}

postfx_destroy :: proc(demo: ^Scene, gfx: ^gbbfx.Gfx) {
	state := cast(^Postfx_State)demo.state
	engine.world_destroy(&state.world)
	free(state)
}
