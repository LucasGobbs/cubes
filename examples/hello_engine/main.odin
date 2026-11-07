// Minimal engine app: one animated character with a bloom post-process.
// Run from the repo root so the asset path resolves.
package main

import "core:math/linalg"
import engine "../../src/engine"

HERO_MODEL :: "static/models/rigged_cesiumman.glb"

App :: struct {
	hero: engine.Entity_Id,
}

main :: proc() {
	app: App
	engine.run(&app, start, update, title = "hello_engine")
}

start :: proc(app: ^App, world: ^engine.World) {
	engine.world_spawn(
		world,
		engine.Camera{look_at = engine.Vec3{0, 0.8, 0}, bloom = engine.Bloom{threshold = 0.5, intensity = 1.5, radius = 12}},
		engine.Transform{position = {0, 1, 1.9}},
	)
	app.hero = engine.world_spawn(world, engine.Model{path = HERO_MODEL}, engine.Animator{clip = "clip_0"})
}

update :: proc(app: ^App, world: ^engine.World, dt: f32) {
	transform := engine.world_get(world, app.hero, engine.Transform)
	transform.rotation = linalg.quaternion_angle_axis_f32(dt, {0, 1, 0}) * transform.rotation
}
