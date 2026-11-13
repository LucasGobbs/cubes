// Key 3 — Models: every OBJ in static/ on a textured ground plane, each
// rotating at its own speed.
package models

import engine "../../engine"
import default "../../engine/default"
import gfx "../../engine/gfx"
import "core:math/linalg"

MODEL_PATHS :: [4]string {
	"static/models/sea/boat-tug-a.glb",
	"static/models/sea/ship-cargo-a.glb",
	"static/models/sea/ship-large.glb",
	"static/models/sea/ship-small-ghost.glb",
}

MODEL_SCALE :: [3]f32{0.5, 0.5, 0.5}

Models_State :: struct {
	ship_draws: [4]int,
	rotation:   f32,
}

models_scene :: proc() -> engine.Scene {
	return {name = "Models", create = models_create, tick = models_tick, destroy = models_destroy}
}

// Ships sit in a row along x, all at z = -16.
models_position :: proc(index: int) -> [3]f32 {
	return {(f32(index) - 1.5) * 8, 0, -16}
}

models_create :: proc(scene: ^engine.Scene, ctx: ^engine.Context) -> bool {
	state := new(Models_State)
	scene.state = state
	engine.camera_fly(ctx, {0, 2, 4})

	for path, index in MODEL_PATHS {
		model := gfx.model_add(&ctx.gfx, {path = path, kind = .Textured})
		state.ship_draws[index] = gfx.draw_create(&ctx.gfx, {mesh = model, position = models_position(index), scale = MODEL_SCALE})
	}
	gfx.skybox_add(&ctx.gfx, default.SKYBOX_PATH)

	// Ground plane: raw quad, tiled mud texture.
	tiling :: f32(40)
	ground := gfx.material_create(&ctx.gfx, {kind = .Textured, texture = "static/muddy_ground.jpg"})
	gfx.draw_create(
		&ctx.gfx,
		{
			mesh = gfx.Mesh_Data {
				vertices = []gfx.VertexData {
					{position = {-100, -1, -100}, color = {1, 1, 1, 1}, normal = {0, 1, 0}, uv = {0, 0}},
					{position = {100, -1, -100}, color = {1, 1, 1, 1}, normal = {0, 1, 0}, uv = {tiling, 0}},
					{position = {100, -1, 100}, color = {1, 1, 1, 1}, normal = {0, 1, 0}, uv = {tiling, tiling}},
					{position = {-100, -1, 100}, color = {1, 1, 1, 1}, normal = {0, 1, 0}, uv = {0, tiling}},
				},
				indices = []u32{0, 2, 1, 0, 3, 2},
			},
			material = ground,
		},
	)
	return true
}

models_tick :: proc(scene: ^engine.Scene, ctx: ^engine.Context, delta_time: f32) {
	state := cast(^Models_State)scene.state
	state.rotation += delta_time
	for draw, index in state.ship_draws {
		gfx.draw_move(
			&ctx.gfx,
			draw,
			models_position(index),
			linalg.quaternion_from_euler_angles_f32(0, state.rotation * (0.4 + 0.3 * f32(index)), 0, .XYZ),
			MODEL_SCALE,
		)
	}
	gfx.render(&ctx.gfx)
}

// Host calls destroy only while state is set; scope_end frees the GPU resources.
models_destroy :: proc(scene: ^engine.Scene, ctx: ^engine.Context) {
	free(cast(^Models_State)scene.state)
}
