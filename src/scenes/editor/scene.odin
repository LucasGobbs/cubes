// Key 2 — Editor: the full setup. Viewport editor (TAB toggles), compute
// blur post-processing, a 300-boat fleet, and an animated raw quad.
package editor_scene

import gfx "../../engine/gfx"
import default "../../engine/default"
import editor "../../editor"
import "core:math/linalg"
import "core:math/rand"
import sdl "vendor:sdl3"
import engine "../../engine"

BOAT_COLS :: 20
BOAT_ROWS :: 15 // 300 boats

Editor_State :: struct {
	textured_pipeline: gfx.Pipeline_Handle,
	unlit_pipeline:    gfx.Pipeline_Handle,
	sampler:           gfx.Sampler_Handle,
	textured_model:    gfx.Model,
	unlit_model:       gfx.Model,
	shared_material:   gfx.Material,
	quad_vertices:     [4]gfx.VertexData,
	quad_indices:      [6]u16,
	quad_mesh:         gfx.Mesh,
	blur:              gfx.Blur,
	ui:                editor.Ui_State,
	editor:            ^editor.Editor,
	tint:              [4]f32,
	center_entity:     int,
	rotation_speed:    f32,
	rotation:          f32,

	fly_camera:        gfx.Fly_Camera,
	fly_controls:      engine.Fly_Controls,
}

editor_scene :: proc() -> engine.Scene {
	return {name = "Editor", create = ed_create, tick = ed_tick, destroy = ed_destroy}
}

ed_event_hook :: proc(event: ^sdl.Event, user_data: rawptr) {
	editor.editor_handle_event(cast(^editor.Editor)user_data, event)
}

ed_create :: proc(demo: ^engine.Scene, ctx: ^engine.Context) -> bool {
	gfx_ctx := &ctx.gfx
	state := new(Editor_State)
	demo.state = state
	engine.scene_camera_reset(demo, gfx_ctx)

	state.fly_camera = gfx.fly_camera_create()
	state.fly_controls = engine.fly_controls_create(&ctx.input, "editor")

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
		{model_path = "static/models/sea/ship-large.glb", pipeline = state.unlit_pipeline},
	)
	gfx.set_unlit_color(&state.unlit_model.material, {0.15, 0.85, 0.3, 1})

	gfx.skybox_add(gfx_ctx, default.SKYBOX_PATH)
	gfx.draw_create(gfx_ctx, {mesh = &state.textured_model, position = {-5, -.5, -12}, scale = {0.4, 0.4, 0.4}})
	state.center_entity = gfx.draw_create(gfx_ctx, {mesh = &state.textured_model, position = {0, -.5, -12}, scale = {0.4, 0.4, 0.4}})
	gfx.draw_create(gfx_ctx, {mesh = &state.unlit_model, position = {5, -.5, -12}, scale = {0.4, 0.4, 0.4}})

	// One material shared by any number of entities; the editor edits
	// state.tint live.
	state.shared_material = gfx.material_make(state.unlit_pipeline)
	state.tint = {0.95, 0.85, 0.2, 1}
	gfx.set_unlit_color(&state.shared_material, state.tint)

	gfx.draw_create(gfx_ctx, {mesh = &state.unlit_model.mesh, material = &state.shared_material, position = {0, 1.2, -12}, scale = {0.4, 0.4, 0.4}})

	state.quad_vertices = {
		{position = {-1, -1, 0}, color = {1, 1, 1, 1}, uv = {0, 0}},
		{position = {1, -1, 0}, color = {1, 1, 1, 1}, uv = {1, 0}},
		{position = {1, 1, 0}, color = {1, 1, 1, 1}, uv = {1, 1}},
		{position = {-1, 1, 0}, color = {1, 1, 1, 1}, uv = {0, 1}},
	}
	state.quad_indices = {0, 1, 2, 2, 3, 0}
	state.quad_mesh = gfx.mesh_create(gfx_ctx, state.quad_vertices[:], state.quad_indices[:])
	gfx.draw_create(gfx_ctx, {mesh = &state.quad_mesh, material = &state.shared_material, position = {0, 1.2, -8}, layer = .UI})

	// Post-processing: separable gaussian blur over scene_color, run by the
	// renderer after the scene (renderer_run_post).
	state.blur = gfx.blur_create(gfx_ctx, 2)
	gfx.renderer_set_passes(&gfx_ctx.renderer, .Post, []gfx.Render_Pass{gfx.blur_pass(&state.blur)})

	when gfx.EDITOR {
		state.editor = new(editor.Editor)
		ok := editor.editor_init(gfx_ctx, state.editor)
		assert(ok)
		engine.set_event_hook(ctx, ed_event_hook, state.editor)
		_ = sdl.SetWindowRelativeMouseMode(gfx_ctx.window, false)
	}

	// A small fleet: jittered grid placements with random yaw and scale.
	rand.reset(u64(sdl.GetTicks()))
	for index in 0 ..< BOAT_COLS * BOAT_ROWS {
		column := f32(index % BOAT_COLS)
		row := f32(index / BOAT_COLS)
		position := gfx.Vec3 {
			(column - BOAT_COLS / 2) * 6 + rand.float32_range(-2, 2),
			-0.5,
			(row - BOAT_ROWS / 2) * 6 - 55 + rand.float32_range(-2, 2),
		}
		yaw := linalg.quaternion_from_euler_angles_f32(
			0,
			rand.float32_range(0, linalg.TAU),
			0,
			.XYZ,
		)
		scale := 0.25 + rand.float32_range(0, 0.2)
		gfx.draw_create(gfx_ctx, {mesh = &state.textured_model, position = position, scale = {scale, scale, scale}, rotation = yaw})
	}

	state.rotation_speed = linalg.to_radians(f32(90))
	state.ui.rotation_speed = &state.rotation_speed
	state.ui.tint = &state.tint
	return true
}

ed_tick :: proc(demo: ^engine.Scene, ctx: ^engine.Context, delta_time: f32) {
	gfx_ctx := &ctx.gfx
	state := cast(^Editor_State)demo.state

	// Mouse-look only when the cursor is over the viewport widget (always
	// when the editor is hidden or not compiled in).
	mouse_in_viewport := true
	when gfx.EDITOR {
		mouse_in_viewport = editor.editor_mouse_in_viewport(state.editor, state.ui.viewport)
	}
	fly := engine.fly_controls_read(&ctx.input, &state.fly_controls, mouse_in_viewport)
	gfx.fly_camera_update(gfx.camera(gfx_ctx), &state.fly_camera, fly, delta_time)

	when gfx.EDITOR {
		camera := gfx.camera(gfx_ctx)
		state.ui.fps = 1 / delta_time
		editor.editor_build_ui(state.editor, &state.ui)
		gfx.set_unlit_color(&state.shared_material, state.tint)

		// The game renders at the Viewport widget's size; when the editor
		// is hidden it takes the whole window again.
		if state.editor.visible {
			vp := state.ui.viewport
			if vp.w > 0 && vp.h > 0 {
				gfx.renderer_resize_targets(&gfx_ctx.renderer, u32(vp.w), u32(vp.h))
				gfx.camera_set_aspect(camera, f32(vp.w) / f32(vp.h))
			}
		} else {
			gfx.renderer_resize_targets(&gfx_ctx.renderer, u32(gfx_ctx.window_size.x), u32(gfx_ctx.window_size.y))
			gfx.camera_set_aspect(camera, gfx.aspect_ratio(gfx_ctx))
		}
	}

	// Rebuild the quad's geometry every frame and re-upload it.
	state.quad_vertices[2].position.y = 1 + 0.5 * linalg.sin(ctx.time * 2)
	state.quad_vertices[3].position.y = 1 - 0.5 * linalg.sin(ctx.time * 2)
	gfx.mesh_update(&gfx_ctx.renderer, &state.quad_mesh, state.quad_vertices[:], state.quad_indices[:])

	state.rotation += state.rotation_speed * delta_time
	gfx.draw_set_transform(
		gfx.draw_get(gfx_ctx, state.center_entity),
		{0, -.5, -12},
		linalg.quaternion_from_euler_angles_f32(0, state.rotation, 0, .XYZ),
		{0.4, 0.4, 0.4},
	)

	// Frame flow: scene -> offscreen, post passes -> final, editor overlay
	// (or plain present) -> swapchain.
	gfx.renderer_begin_frame(&gfx_ctx.renderer)
	gfx.renderer_render_draws(&gfx_ctx.renderer, gfx_ctx.draws[:])
	if gfx_ctx.swapchain != nil {
		final := gfx.renderer_run_post(&gfx_ctx.renderer)
		when gfx.EDITOR {
			if state.editor.visible {
				editor.editor_draw(state.editor, gfx_ctx, final, state.ui.viewport)
			} else {
				gfx.renderer_present(&gfx_ctx.renderer, final)
			}
		} else {
			gfx.renderer_present(&gfx_ctx.renderer, final)
		}
	}
	gfx.end_frame(gfx_ctx)
}

ed_destroy :: proc(demo: ^engine.Scene, ctx: ^engine.Context) {
	gfx_ctx := &ctx.gfx
	state := cast(^Editor_State)demo.state
	engine.set_event_hook(ctx, nil, nil)
	_ = sdl.SetWindowRelativeMouseMode(gfx_ctx.window, true)
	when gfx.EDITOR {
		editor.editor_destroy(state.editor)
		free(state.editor)
	}
	gfx.renderer_clear_passes(&gfx_ctx.renderer, .Post) // passes point into state
	gfx.material_destroy(&state.shared_material)
	gfx.model_unload(gfx_ctx, &state.textured_model)
	gfx.model_unload(gfx_ctx, &state.unlit_model)
	free(state)
}
