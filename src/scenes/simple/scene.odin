// Simple scene: one textured ship, one unlit ship, one animated raw quad.
package simple

import "core:math/linalg"
import gfx "../../engine/gfx"
import default "../../engine/default"
import engine "../../engine"

SPIN_SHIP_POSITION :: [3]f32{-2.5, -0.5, -10}
SHIP_SCALE :: [3]f32{0.4, 0.4, 0.4}

Simple_State :: struct {
	textured_pipeline: gfx.Pipeline_Handle,
	unlit_pipeline:    gfx.Pipeline_Handle,
	sampler:           gfx.Sampler_Handle,
	textured_model:    gfx.Model,
	unlit_model:       gfx.Model,
	quad_mesh:         gfx.Mesh,
	quad_vertices:     [4]gfx.VertexData,
	quad_indices:      [6]u16,
	draws:             [dynamic]gfx.Draw,
	skybox:            gfx.Skybox,
	spinning:          int,
	rotation:          f32,
	fly_camera:        gfx.Fly_Camera,
	fly_controls:      engine.Fly_Controls,
	// move_action:       input.Axis_2D_Action,
	// boost_action:      input.Button_Action,
	// up_action:         input.Button_Action,
	// down_action:       input.Button_Action,
}

simple_scene :: proc() -> engine.Scene {
	return {name = "Simple", create = simple_create, tick = simple_tick, destroy = simple_destroy}
}

simple_create :: proc(demo: ^engine.Scene, ctx: ^engine.Context) -> bool {
	gfx_ctx := &ctx.gfx
	state := new(Simple_State)
	demo.state = state
	engine.scene_camera_reset(demo, gfx_ctx)

	state.fly_camera = gfx.fly_camera_create()
	state.fly_controls = engine.fly_controls_create(&ctx.input, "simple")

	state.textured_pipeline = gfx.create_textured_pipeline(gfx_ctx)
	state.unlit_pipeline = gfx.create_unlit_pipeline(gfx_ctx)
	state.sampler = gfx.sampler_create(gfx_ctx, gfx.SAMPLER_TRILINEAR)

	state.textured_model = gfx.load_textured_model(
		gfx_ctx,
		"static/models/sea/ship-large.glb",
		state.textured_pipeline,
		state.sampler,
	)
	state.unlit_model = gfx.model_load(
		gfx_ctx,
		{model_path = "static/models/sea/ship-small-ghost.glb", pipeline = state.unlit_pipeline},
	)
	gfx.set_unlit_color(&state.unlit_model.material, {0.2, 0.8, 0.9, 1})

	state.skybox = gfx.skybox_create(gfx_ctx, default.SKYBOX_PATH)
	append(&state.draws, gfx.skybox_draw(&state.skybox))

	append(&state.draws, gfx.draw_model(&state.textured_model, SPIN_SHIP_POSITION, SHIP_SCALE))
	state.spinning = len(state.draws) - 1
	append(&state.draws, gfx.draw_model(&state.unlit_model, {2.5, -0.5, -10}, SHIP_SCALE))

	// Raw geometry: animated quad through the unlit pipeline.
	state.quad_vertices = {
		{position = {-1, -1, 0}, color = {1, 1, 1, 1}, normal = {0, 0, 1}, uv = {0, 0}},
		{position = {1, -1, 0}, color = {1, 1, 1, 1}, normal = {0, 0, 1}, uv = {1, 0}},
		{position = {1, 1, 0}, color = {1, 1, 1, 1}, normal = {0, 0, 1}, uv = {1, 1}},
		{position = {-1, 1, 0}, color = {1, 1, 1, 1}, normal = {0, 0, 1}, uv = {0, 1}},
	}
	state.quad_indices = {0, 1, 2, 2, 3, 0}
	state.quad_mesh = gfx.mesh_create(gfx_ctx, state.quad_vertices[:], state.quad_indices[:])
	gfx.mesh_upload(&gfx_ctx.renderer, &state.quad_mesh)
	append(
		&state.draws,
		gfx.draw_make(&state.quad_mesh, &state.unlit_model.material, {0, 1.2, -8}, layer = .UI),
	)
	return true
}

simple_tick :: proc(demo: ^engine.Scene, ctx: ^engine.Context, delta_time: f32) {
	gfx_ctx := &ctx.gfx
	state := cast(^Simple_State)demo.state

	fly := engine.fly_controls_read(&ctx.input, &state.fly_controls)
	gfx.fly_camera_update(gfx.camera(gfx_ctx), &state.fly_camera, fly, delta_time)

	state.rotation += linalg.to_radians(f32(60)) * delta_time
	gfx.draw_set_transform(
		&state.draws[state.spinning],
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

	gfx.render(gfx_ctx, state.draws[:])
}

simple_destroy :: proc(demo: ^engine.Scene, ctx: ^engine.Context) {
	gfx_ctx := &ctx.gfx
	state := cast(^Simple_State)demo.state
	delete(state.draws)
	gfx.skybox_destroy(gfx_ctx, &state.skybox)
	gfx.mesh_destroy(gfx_ctx, &state.quad_mesh)
	gfx.model_unload(gfx_ctx, &state.textured_model)
	gfx.model_unload(gfx_ctx, &state.unlit_model)
	gfx.sampler_destroy(gfx_ctx, state.sampler)
	gfx.pipeline_destroy(gfx_ctx, state.textured_pipeline)
	gfx.pipeline_destroy(gfx_ctx, state.unlit_pipeline)
	free(state)
}
