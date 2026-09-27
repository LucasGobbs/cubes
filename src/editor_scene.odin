// Key 2 — Editor: the full setup. Viewport editor (TAB toggles), compute
// blur post-processing, a 300-boat fleet, and an animated raw quad.
package main

import gbbfx "gbbfx"
import defaults "gbbfx/defaults"
import editor "editor"
import glove "glove"
import shader_parameters "shader_parameters"
import "core:math/linalg"
import "core:math/rand"
import sdl "vendor:sdl3"

BOAT_COLS :: 20
BOAT_ROWS :: 15 // 300 boats

Editor_State :: struct {
	textured_pipeline: gbbfx.Pipeline_Handle,
	unlit_pipeline:    gbbfx.Pipeline_Handle,
	sampler:           gbbfx.Sampler_Handle,
	textured_model:    gbbfx.Model,
	unlit_model:       gbbfx.Model,
	shared_material:   gbbfx.Material,
	quad_vertices:     [4]gbbfx.VertexData,
	quad_indices:      [6]u16,
	quad_mesh:         gbbfx.Mesh,
	blur_pipeline:     gbbfx.Compute_Pipeline_Handle,
	blur_target:       gbbfx.Texture_Handle,
	ui:                editor.Ui_State,
	editor:            ^editor.Editor,
	tint:              [4]f32,
	scene:             gbbfx.Scene,
	center_entity:     int,
	mouse_sensitivity: f32,
	rotation_speed:    f32,
	rotation:          f32,

	move_action:       glove.Axis_2D_Action,
	boost_action:      glove.Button_Action,
	up_action:         glove.Button_Action,
	down_action:       glove.Button_Action,
}

editor_scene :: proc() -> Scene {
	return {name = "Editor", create = ed_create, tick = ed_tick, destroy = ed_destroy}
}

ed_event_hook :: proc(event: ^sdl.Event, user_data: rawptr) {
	editor.editor_handle_event(cast(^editor.Editor)user_data, event)
}

ed_create :: proc(demo: ^Scene, gfx: ^gbbfx.Gfx) -> bool {
	state := new(Editor_State)
	demo.state = state
	camera_reset(gfx)

	inputs := gbbfx.gfx_input(gfx)
	state.move_action = glove.add_axis_2d(inputs, "editor.move")
	state.boost_action = glove.add_button(inputs, "editor.boost")
	state.up_action = glove.add_button(inputs, "editor.up")
	state.down_action = glove.add_button(inputs, "editor.down")
	glove.bind_button_axis_2d(
		inputs,
		state.move_action,
		{up = .W, down = .S, left = .A, right = .D, normalize = true},
	)
	glove.bind_key(inputs, state.boost_action, .LSHIFT)
	glove.bind_key(inputs, state.up_action, .SPACE)
	glove.bind_key(inputs, state.down_action, .LCTRL)

	state.textured_pipeline = defaults.create_textured_pipeline(gfx)
	state.unlit_pipeline = defaults.create_unlit_pipeline(gfx)
	state.sampler = gbbfx.gfx_sampler_create(gfx)

	state.textured_model = load_textured_model(
		gfx,
		"static/ship-large.obj",
		"static/colormap.png",
		state.textured_pipeline,
		state.sampler,
	)
	state.unlit_model = gbbfx.gfx_load(
		gfx,
		{model_path = "static/ship-large.obj", pipeline = state.unlit_pipeline},
	)
	defaults.set_unlit_color(&state.unlit_model.material, {0.15, 0.85, 0.3, 1})

	gbbfx.scene_add_model(&state.scene, &state.textured_model, {-5, -.5, -12}, {0.4, 0.4, 0.4})
	state.center_entity = gbbfx.scene_add_model(
		&state.scene,
		&state.textured_model,
		{0, -.5, -12},
		{0.4, 0.4, 0.4},
	)
	gbbfx.scene_add_model(&state.scene, &state.unlit_model, {5, -.5, -12}, {0.4, 0.4, 0.4})

	// One material shared by any number of entities; the editor edits
	// state.tint live.
	state.shared_material = gbbfx.material_create(state.unlit_pipeline)
	state.tint = {0.95, 0.85, 0.2, 1}
	defaults.set_unlit_color(&state.shared_material, state.tint)

	shared_ship := gbbfx.scene_add_entity(&state.scene)
	shared_ship_entity := gbbfx.scene_entity(&state.scene, shared_ship)
	gbbfx.entity_set_position(shared_ship_entity, {0, 1.2, -12})
	gbbfx.entity_set_scale(shared_ship_entity, {0.4, 0.4, 0.4})
	gbbfx.entity_add_renderable(shared_ship_entity, &state.unlit_model.mesh, &state.shared_material)

	state.quad_vertices = {
		{position = {-1, -1, 0}, color = {1, 1, 1, 1}, uv = {0, 0}},
		{position = {1, -1, 0}, color = {1, 1, 1, 1}, uv = {1, 0}},
		{position = {1, 1, 0}, color = {1, 1, 1, 1}, uv = {1, 1}},
		{position = {-1, 1, 0}, color = {1, 1, 1, 1}, uv = {0, 1}},
	}
	state.quad_indices = {0, 1, 2, 2, 3, 0}
	state.quad_mesh = gbbfx.mesh_create(gfx, state.quad_vertices[:], state.quad_indices[:])
	gbbfx.mesh_upload(&gfx.renderer, &state.quad_mesh)
	quad := gbbfx.scene_add_entity(&state.scene)
	quad_entity := gbbfx.scene_entity(&state.scene, quad)
	gbbfx.entity_set_position(quad_entity, {0, 1.2, -8})
	gbbfx.entity_add_renderable(quad_entity, &state.quad_mesh, &state.shared_material, .UI)

	// Compute post-processing: 5x5 box blur, scene -> blur_target.
	state.blur_pipeline = gbbfx.gfx_compute_pipeline_create(gfx, shader_parameters.blur_compute())
	blur_format := sdl.GetGPUSwapchainTextureFormat(gfx.gpu, gfx.window)
	if !sdl.GPUTextureSupportsFormat(gfx.gpu, blur_format, .D2, {.COMPUTE_STORAGE_WRITE}) {
		blur_format = .R8G8B8A8_UNORM
	}
	state.blur_target = gbbfx.gfx_texture_create_with_usage(
		gfx,
		u32(gfx.window_size.x),
		u32(gfx.window_size.y),
		blur_format,
		{.COMPUTE_STORAGE_WRITE, .SAMPLER},
	)

	when gbbfx.EDITOR {
		state.editor = new(editor.Editor)
		ok := editor.editor_init(gfx, state.editor)
		assert(ok)
		gbbfx.gfx_set_event_hook(gfx, ed_event_hook, state.editor)
		_ = sdl.SetWindowRelativeMouseMode(gfx.window, false)
	}

	// A small fleet: jittered grid placements with random yaw and scale.
	rand.reset(u64(sdl.GetTicks()))
	for index in 0 ..< BOAT_COLS * BOAT_ROWS {
		column := f32(index % BOAT_COLS)
		row := f32(index / BOAT_COLS)
		position := gbbfx.Vec3 {
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
		gbbfx.scene_add_model(&state.scene, &state.textured_model, position, {scale, scale, scale}, yaw)
	}

	state.mouse_sensitivity = linalg.to_radians(f32(0.1))
	state.rotation_speed = linalg.to_radians(f32(90))
	state.ui.rotation_speed = &state.rotation_speed
	state.ui.tint = &state.tint
	return true
}

ed_tick :: proc(demo: ^Scene, gfx: ^gbbfx.Gfx, delta_time: f32) {
	state := cast(^Editor_State)demo.state

	// Mouse-look only when the cursor is over the viewport widget (always
	// when the editor is hidden or not compiled in).
	mouse_in_viewport := true
	when gbbfx.EDITOR {
		mouse_in_viewport = editor.editor_mouse_in_viewport(state.editor, state.ui.viewport)
	}
	camera := gbbfx.gfx_camera(gfx)
	inputs := gbbfx.gfx_input(gfx)
	if mouse_in_viewport {
		look := glove.mouse_delta(inputs)
		gbbfx.camera_rotate(camera, look.x * state.mouse_sensitivity, -look.y * state.mouse_sensitivity)
	}
	move := glove.axis_2d(inputs, state.move_action)
	vertical: f32
	if glove.down(inputs, state.up_action) do vertical += 1
	if glove.down(inputs, state.down_action) do vertical -= 1
	boost: f32 = 1
	if glove.down(inputs, state.boost_action) do boost = 4
	move_direction := camera.direction * move.y + camera.right * move.x + gbbfx.Vec3{0, vertical, 0}
	if move_direction != {} {
		camera.position += move_direction * f32(5) * boost * delta_time
	}

	when gbbfx.EDITOR {
		state.ui.fps = 1 / delta_time
		editor.editor_build_ui(state.editor, &state.ui)
		defaults.set_unlit_color(&state.shared_material, state.tint)

		// The game renders at the Viewport widget's size; when the editor
		// is hidden it takes the whole window again.
		if state.editor.visible {
			vp := state.ui.viewport
			if vp.w > 0 && vp.h > 0 {
				gbbfx.gfx_texture_resize(gfx, &gfx.renderer.scene_color, u32(vp.w), u32(vp.h))
				gbbfx.gfx_texture_resize(gfx, &state.blur_target, u32(vp.w), u32(vp.h))
				gbbfx.camera_set_aspect(camera, f32(vp.w) / f32(vp.h))
			}
		} else {
			gbbfx.gfx_texture_resize(gfx, &gfx.renderer.scene_color, u32(gfx.window_size.x), u32(gfx.window_size.y))
			gbbfx.gfx_texture_resize(gfx, &state.blur_target, u32(gfx.window_size.x), u32(gfx.window_size.y))
			gbbfx.camera_set_aspect(camera, gbbfx.gfx_aspect_ratio(gfx))
		}
	}

	// Rebuild the quad's geometry every frame and re-upload it.
	state.quad_vertices[2].position.y = 1 + 0.5 * linalg.sin(gfx.time * 2)
	state.quad_vertices[3].position.y = 1 - 0.5 * linalg.sin(gfx.time * 2)
	gbbfx.mesh_update(&gfx.renderer, &state.quad_mesh, state.quad_vertices[:], state.quad_indices[:])

	state.rotation += state.rotation_speed * delta_time
	gbbfx.entity_set_rotation_euler(
		gbbfx.scene_entity(&state.scene, state.center_entity),
		0,
		state.rotation,
		0,
	)

	// Frame flow: scene -> offscreen, blur -> blur_target, editor overlay
	// (or plain present) -> swapchain.
	gbbfx.renderer_begin_frame(&gfx.renderer)
	gbbfx.renderer_render_scene(&gfx.renderer, &state.scene)
	if gfx.swapchain != nil {
		blur_size := gbbfx.gfx_texture_get(gfx, state.blur_target)
		groups := [3]u32{(blur_size.width + 7) / 8, (blur_size.height + 7) / 8, 1}
		writes := [1]gbbfx.Texture_Handle{state.blur_target}
		reads := [1]gbbfx.Texture_Handle{gfx.renderer.scene_color}
		gbbfx.gfx_compute_dispatch(gfx, state.blur_pipeline, writes[:], reads[:], state.sampler, groups)
		when gbbfx.EDITOR {
			if state.editor.visible {
				editor.editor_draw(state.editor, gfx, state.blur_target, state.ui.viewport)
			} else {
				gbbfx.renderer_present(&gfx.renderer, state.blur_target)
			}
		} else {
			gbbfx.renderer_present(&gfx.renderer, state.blur_target)
		}
	}
	gbbfx.gfx_end_frame(gfx)
}

ed_destroy :: proc(demo: ^Scene, gfx: ^gbbfx.Gfx) {
	state := cast(^Editor_State)demo.state
	gbbfx.gfx_set_event_hook(gfx, nil, nil)
	_ = sdl.SetWindowRelativeMouseMode(gfx.window, true)
	gbbfx.scene_destroy(&state.scene)
	when gbbfx.EDITOR {
		editor.editor_destroy(gfx, state.editor)
		free(state.editor)
	}
	gbbfx.gfx_compute_pipeline_destroy(gfx, state.blur_pipeline)
	gbbfx.gfx_texture_destroy(gfx, state.blur_target)
	gbbfx.mesh_destroy(gfx, &state.quad_mesh)
	gbbfx.material_destroy(&state.shared_material)
	gbbfx.gfx_unload(gfx, &state.textured_model)
	gbbfx.gfx_unload(gfx, &state.unlit_model)
	gbbfx.gfx_sampler_destroy(gfx, state.sampler)
	gbbfx.gfx_pipeline_destroy(gfx, state.textured_pipeline)
	gbbfx.gfx_pipeline_destroy(gfx, state.unlit_pipeline)
	free(state)
}
