// Simple scene: one textured ship, one unlit ship, one animated raw quad.
package simple

import "core:math/linalg"
import gfx "../../engine/gfx"
import default "../../engine/default"
import engine "../../engine"

SPIN_SHIP_POSITION :: [3]f32{-2.5, -0.5, -10}
SHIP_SCALE :: [3]f32{0.4, 0.4, 0.4}

Simple_State :: struct {
	quad_mesh:     gfx.Mesh,
	quad_vertices: [4]gfx.VertexData,
	quad_indices:  [6]u16,
	spinning:      int,
	rotation:      f32,
}

simple_scene :: proc() -> engine.Scene {
	return {name = "Simple", create = simple_create, tick = simple_tick, destroy = simple_destroy}
}

simple_create :: proc(demo: ^engine.Scene, ctx: ^engine.Context) -> bool {
	gfx_ctx := &ctx.gfx
	state := new(Simple_State)
	demo.state = state
	engine.camera_fly(ctx)

	textured := gfx.model_add(gfx_ctx, {path = "static/models/sea/ship-large.glb", kind = .Textured})
	unlit := gfx.model_add(
		gfx_ctx,
		{path = "static/models/sea/ship-small-ghost.glb", kind = .Unlit, tint = {0.2, 0.8, 0.9, 1}},
	)

	gfx.skybox_add(gfx_ctx, default.SKYBOX_PATH)

	state.spinning = gfx.draw_create(gfx_ctx, {mesh = textured, position = SPIN_SHIP_POSITION, scale = SHIP_SCALE})
	gfx.draw_create(gfx_ctx, {mesh = unlit, position = {2.5, -0.5, -10}, scale = SHIP_SCALE})

	// Raw geometry: animated quad through the unlit pipeline.
	state.quad_vertices = {
		{position = {-1, -1, 0}, color = {1, 1, 1, 1}, normal = {0, 0, 1}, uv = {0, 0}},
		{position = {1, -1, 0}, color = {1, 1, 1, 1}, normal = {0, 0, 1}, uv = {1, 0}},
		{position = {1, 1, 0}, color = {1, 1, 1, 1}, normal = {0, 0, 1}, uv = {1, 1}},
		{position = {-1, 1, 0}, color = {1, 1, 1, 1}, normal = {0, 0, 1}, uv = {0, 1}},
	}
	state.quad_indices = {0, 1, 2, 2, 3, 0}
	state.quad_mesh = gfx.mesh_create(gfx_ctx, state.quad_vertices[:], state.quad_indices[:])
	quad_material := gfx.material_create(gfx_ctx, {kind = .Unlit, tint = {0.2, 0.8, 0.9, 1}})
	gfx.draw_create(gfx_ctx, {mesh = &state.quad_mesh, material = quad_material, position = {0, 1.2, -8}, layer = .UI})
	return true
}

simple_tick :: proc(demo: ^engine.Scene, ctx: ^engine.Context, delta_time: f32) {
	gfx_ctx := &ctx.gfx
	state := cast(^Simple_State)demo.state

	state.rotation += linalg.to_radians(f32(60)) * delta_time
	gfx.draw_move(
		gfx_ctx,
		state.spinning,
		SPIN_SHIP_POSITION,
		linalg.quaternion_from_euler_angles_f32(0, state.rotation, 0, .XYZ),
		SHIP_SCALE,
	)

	state.quad_vertices[2].position.y = 1 + 0.5 * linalg.sin(ctx.time * 2)
	state.quad_vertices[3].position.y = 1 - 0.5 * linalg.sin(ctx.time * 2)
	gfx.mesh_update(
		&gfx_ctx.renderer,
		&state.quad_mesh,
		state.quad_vertices[:],
		state.quad_indices[:],
	)

	gfx.render(gfx_ctx)
}

simple_destroy :: proc(demo: ^engine.Scene, ctx: ^engine.Context) {
	state := cast(^Simple_State)demo.state
	free(state)
}
