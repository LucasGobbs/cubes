// Benchmark: N instances of each of the 4 models, with on-screen text
// (FPS, object count, controls) drawn through the gbbfx font renderer.
// = / - add and remove instances.
package main

import gbbfx "gbbfx"
import defaults "gbbfx/defaults"
import glove "glove"
import "core:fmt"
import "core:math/linalg"
import "core:math/rand"
import sdl "vendor:sdl3"

BENCH_STEP :: 25 // per model, per keypress (= ±100 total)

Benchmark_State :: struct {
	pipeline:          gbbfx.Pipeline_Handle,
	sampler:           gbbfx.Sampler_Handle,
	models:            [4]gbbfx.Model,
	scene:             gbbfx.Scene,
	per_model:         int,

	font:              gbbfx.Font,
	overlay_pipeline:  gbbfx.Pipeline_Handle,
	overlay_material:  gbbfx.Material,
	text_mesh:         gbbfx.Mesh,
	text_vertices:     [dynamic]gbbfx.VertexData,

	move_action:       glove.Axis_2D_Action,
	boost_action:      glove.Button_Action,
	up_action:         glove.Button_Action,
	down_action:       glove.Button_Action,
	add_action:        glove.Button_Action,
	subtract_action:   glove.Button_Action,
}

benchmark_scene :: proc() -> Scene {
	return {name = "Benchmark", create = benchmark_create, tick = benchmark_tick, destroy = benchmark_destroy}
}

benchmark_create :: proc(demo: ^Scene, gfx: ^gbbfx.Gfx) -> bool {
	state := new(Benchmark_State)
	demo.state = state
	camera_reset(gfx, {0, 8, 20})
	// Uncapped: the point of this scene is measuring real frame cost.
	gbbfx.gfx_set_present_mode(gfx, .IMMEDIATE)

	inputs := gbbfx.gfx_input(gfx)
	state.move_action = glove.add_axis_2d(inputs, "benchmark.move")
	state.boost_action = glove.add_button(inputs, "benchmark.boost")
	state.up_action = glove.add_button(inputs, "benchmark.up")
	state.down_action = glove.add_button(inputs, "benchmark.down")
	state.add_action = glove.add_button(inputs, "benchmark.add")
	state.subtract_action = glove.add_button(inputs, "benchmark.subtract")
	glove.bind_button_axis_2d(
		inputs,
		state.move_action,
		{up = .W, down = .S, left = .A, right = .D, normalize = true},
	)
	glove.bind_key(inputs, state.boost_action, .LSHIFT)
	glove.bind_key(inputs, state.up_action, .SPACE)
	glove.bind_key(inputs, state.down_action, .LCTRL)
	glove.bind_key(inputs, state.add_action, .EQUALS)
	glove.bind_key(inputs, state.subtract_action, .MINUS)

	state.pipeline = defaults.create_textured_pipeline(gfx)
	state.sampler = gbbfx.gfx_sampler_create(gfx)
	for path, index in MODEL_PATHS {
		state.models[index] = load_textured_model(
			gfx,
			path,
			"static/colormap.png",
			state.pipeline,
			state.sampler,
		)
	}

	// On-screen text: font atlas + blended depth-less overlay pipeline.
	font, font_ok := gbbfx.font_create(gfx, "static/fonts/andale-mono.ttf")
	assert(font_ok)
	state.font = font
	state.overlay_pipeline = defaults.create_textured_overlay_pipeline(gfx)
	state.overlay_material = gbbfx.material_create(state.overlay_pipeline)
	defaults.bind_textured_material(&state.overlay_material, state.font.texture, state.sampler)
	dummy := [6]gbbfx.VertexData{}
	state.text_mesh = gbbfx.mesh_create_unindexed(gfx, dummy[:])
	gbbfx.mesh_upload(&gfx.renderer, &state.text_mesh)

	rand.reset(u64(sdl.GetTicks()))
	benchmark_populate(state, 150)
	return true
}

// Rebuilds the entity list at a new per-model instance count. Models stay
// loaded; only scene entities are recreated.
benchmark_populate :: proc(state: ^Benchmark_State, per_model: int) {
	state.per_model = per_model
	gbbfx.scene_destroy(&state.scene)
	state.scene = {}
	for &model in state.models {
		for _ in 0 ..< per_model {
			position := gbbfx.Vec3 {
				rand.float32_range(-80, 80),
				-0.5,
				rand.float32_range(-180, -20),
			}
			yaw := linalg.quaternion_from_euler_angles_f32(
				0,
				rand.float32_range(0, linalg.TAU),
				0,
				.XYZ,
			)
			scale := 0.25 + rand.float32_range(0, 0.2)
			gbbfx.scene_add_model(&state.scene, &model, position, {scale, scale, scale}, yaw)
		}
	}
}

bench_to_ndc :: proc(x, y, width, height: f32) -> [3]f32 {
	return {x / width * 2 - 1, 1 - y / height * 2, 0}
}

benchmark_push_text :: proc(
	state: ^Benchmark_State,
	gfx: ^gbbfx.Gfx,
	text: string,
	x, top: f32,
	color: [4]f32,
) {
	cursor_x := x
	cursor_y := top + f32(state.font.baseline)
	quads: [dynamic]gbbfx.Font_Quad
	defer delete(quads)
	gbbfx.font_layout(&state.font, text, &cursor_x, &cursor_y, &quads)
	width := f32(gfx.window_size.x)
	height := f32(gfx.window_size.y)
	for quad in quads {
		p0 := bench_to_ndc(quad.x0, quad.y0, width, height)
		p1 := bench_to_ndc(quad.x1, quad.y0, width, height)
		p2 := bench_to_ndc(quad.x1, quad.y1, width, height)
		p3 := bench_to_ndc(quad.x0, quad.y1, width, height)
		uv0 := [2]f32{quad.s0, quad.t0}
		uv1 := [2]f32{quad.s1, quad.t0}
		uv2 := [2]f32{quad.s1, quad.t1}
		uv3 := [2]f32{quad.s0, quad.t1}
		append(
			&state.text_vertices,
			gbbfx.VertexData{position = p0, color = color, uv = uv0},
			gbbfx.VertexData{position = p1, color = color, uv = uv1},
			gbbfx.VertexData{position = p2, color = color, uv = uv2},
			gbbfx.VertexData{position = p0, color = color, uv = uv0},
			gbbfx.VertexData{position = p2, color = color, uv = uv2},
			gbbfx.VertexData{position = p3, color = color, uv = uv3},
		)
	}
}

benchmark_tick :: proc(demo: ^Scene, gfx: ^gbbfx.Gfx, delta_time: f32) {
	state := cast(^Benchmark_State)demo.state

	inputs := gbbfx.gfx_input(gfx)
	if glove.pressed(inputs, state.add_action) {
		benchmark_populate(state, state.per_model + BENCH_STEP)
	}
	if glove.pressed(inputs, state.subtract_action) && state.per_model >= BENCH_STEP {
		benchmark_populate(state, state.per_model - BENCH_STEP)
	}

	camera := gbbfx.gfx_camera(gfx)
	look := glove.mouse_delta(inputs)
	gbbfx.camera_rotate(camera, look.x * 0.1 * linalg.PI / 180, -look.y * 0.1 * linalg.PI / 180)
	move := glove.axis_2d(inputs, state.move_action)
	vertical: f32
	if glove.down(inputs, state.up_action) do vertical += 1
	if glove.down(inputs, state.down_action) do vertical -= 1
	boost: f32 = 1
	if glove.down(inputs, state.boost_action) do boost = 4
	direction := camera.direction * move.y + camera.right * move.x + gbbfx.Vec3{0, vertical, 0}
	if direction != {} do camera.position += direction * f32(5) * boost * delta_time

	// HUD text.
	clear(&state.text_vertices)
	fps_buffer: [32]byte
	benchmark_push_text(
		state, gfx,
		fmt.bprintf(fps_buffer[:], "%.0f FPS", 1 / delta_time),
		10, 10, {1, 1, 1, 1},
	)
	count_buffer: [32]byte
	benchmark_push_text(
		state, gfx,
		fmt.bprintf(count_buffer[:], "objects: %d", state.per_model * len(state.models)),
		10, 30, {1, 1, 1, 1},
	)
	benchmark_push_text(state, gfx, "=/- objects  wasd move  shift fast", 10, 50, {0.8, 0.8, 0.8, 1})
	gbbfx.mesh_update_unindexed(&gfx.renderer, &state.text_mesh, state.text_vertices[:])

	// Frame flow: scene -> offscreen, text into the offscreen, blit out.
	gbbfx.renderer_begin_frame(&gfx.renderer)
	gbbfx.renderer_render_scene(&gfx.renderer, &state.scene)
	if gfx.swapchain != nil {
		renderer := &gfx.renderer
		gbbfx.renderer_begin_overlay_pass(renderer, renderer.scene_color)
		pass := renderer.pass
		pipeline := gbbfx.gfx_pipeline_get(gfx, state.overlay_pipeline)
		sdl.BindGPUGraphicsPipeline(pass, pipeline.handle)
		gbbfx.gfx_pipeline_bind_material(gfx, pass, gfx.command_buffer, &state.overlay_material)
		gbbfx.gfx_pipeline_bind_draw(
			gfx,
			state.overlay_pipeline,
			gfx.command_buffer,
			{
				view_projection = linalg.MATRIX4F32_IDENTITY,
				model_transform = linalg.MATRIX4F32_IDENTITY,
				material = &state.overlay_material,
			},
		)
		vertex_buffer := gbbfx.gfx_buffer_get(gfx, state.text_mesh.vertex_buffer)
		sdl.BindGPUVertexBuffers(pass, 0, &(sdl.GPUBufferBinding{buffer = vertex_buffer.handle}), 1)
		sdl.DrawGPUPrimitives(pass, u32(len(state.text_vertices)), 1, 0, 0)
		gbbfx.renderer_end_pass(renderer)
		gbbfx.renderer_present(renderer, renderer.scene_color)
	}
	gbbfx.gfx_end_frame(gfx)
}

benchmark_destroy :: proc(demo: ^Scene, gfx: ^gbbfx.Gfx) {
	state := cast(^Benchmark_State)demo.state
	gbbfx.scene_destroy(&state.scene)
	delete(state.text_vertices)
	gbbfx.mesh_destroy(gfx, &state.text_mesh)
	gbbfx.material_destroy(&state.overlay_material)
	gbbfx.gfx_pipeline_destroy(gfx, state.overlay_pipeline)
	gbbfx.font_destroy(gfx, &state.font)
	for &model in state.models do gbbfx.gfx_unload(gfx, &model)
	gbbfx.gfx_sampler_destroy(gfx, state.sampler)
	gbbfx.gfx_pipeline_destroy(gfx, state.pipeline)
	free(state)
}
