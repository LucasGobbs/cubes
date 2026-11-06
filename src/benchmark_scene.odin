// Benchmark: N instances of each boat model plus a few huge Stanford dragons, with on-screen text
// (FPS, object count, controls) drawn through the gbbfx font renderer.
// = / - add and remove instances.
package main

import "core:fmt"
import "core:math/linalg"
import "core:math/rand"
import gbbfx "gbbfx"
import defaults "gbbfx/defaults"
import glove "glove"
import sdl "vendor:sdl3"

BENCH_STEP :: 10 // per boat model, per keypress

BOAT_PATHS :: [?]string {
	"static/models/boat-tug-a.glb",
	"static/models/boat-tug-b.glb",
	"static/models/boat-fishing-small.glb",
	"static/models/boat-row-large.glb",
	"static/models/boat-sail-a.glb",
	"static/models/boat-sail-b.glb",
	"static/models/boat-speed-a.glb",
	"static/models/boat-speed-h.glb",
	"static/models/boat-tow-a.glb",
	"static/models/ship-cargo-a.glb",
	"static/models/ship-large.glb",
	"static/models/ship-ocean-liner.glb",
	"static/models/ship-small-ghost.glb",
}
BOAT_COUNT :: len(BOAT_PATHS)

// Dragon mesh is ~140 units long (boats are 3-20): scaled up it towers over
// the fleet. 58k vertices each; one instanced draw for all of them.
DRAGON_PATH :: "static/models/stanford_dragon_pbr.glb"
DRAGON_COUNT :: 3
DRAGON_SCALE :: 0.6

Benchmark_State :: struct {
	pipeline:         gbbfx.Pipeline_Handle,
	sampler:          gbbfx.Sampler_Handle,
	models:           [BOAT_COUNT]gbbfx.Model,
	dragon:           gbbfx.Model,
	scene:            gbbfx.Scene,
	skybox:           defaults.Skybox,
	per_model:        int,
	font:             gbbfx.Font,
	overlay_pipeline: gbbfx.Pipeline_Handle,
	overlay_material: gbbfx.Material,
	text_mesh:        gbbfx.Mesh,
	text_vertices:    [dynamic]gbbfx.VertexData,
	fly_camera:       FlyCamera,
	add_action:       glove.Button_Action,
	subtract_action:  glove.Button_Action,
}

benchmark_scene :: proc() -> Scene {
	return {
		name = "Benchmark",
		create = benchmark_create,
		tick = benchmark_tick,
		destroy = benchmark_destroy,
	}
}

benchmark_create :: proc(demo: ^Scene, gfx: ^gbbfx.Gfx) -> bool {
	state := new(Benchmark_State)
	demo.state = state
	camera_reset(gfx, {0, 8, 20})
	// Uncapped: the point of this scene is measuring real frame cost.
	gbbfx.gfx_set_present_mode(gfx, .IMMEDIATE)

	inputs := gbbfx.gfx_input(gfx)
	state.fly_camera = fly_camera_create(gfx, "benchmark")
	state.add_action = glove.add_button(inputs, "benchmark.add")
	state.subtract_action = glove.add_button(inputs, "benchmark.subtract")
	glove.bind_key(inputs, state.add_action, .EQUALS)
	glove.bind_key(inputs, state.subtract_action, .MINUS)

	state.pipeline = defaults.create_textured_instanced_pipeline(gfx)
	state.sampler = gbbfx.gfx_sampler_create(gfx, gbbfx.SAMPLER_TRILINEAR)
	boat_paths := BOAT_PATHS
	for path, index in boat_paths {
		state.models[index] = gbbfx.gfx_load(gfx, {model_path = path, pipeline = state.pipeline})
		defaults.bind_textured_instanced_material(
			&state.models[index].material,
			gbbfx.model_texture(&state.models[index]),
			state.sampler,
		)
	}
	state.dragon = gbbfx.gfx_load(gfx, {model_path = DRAGON_PATH, pipeline = state.pipeline})
	defaults.bind_textured_instanced_material(
		&state.dragon.material,
		gbbfx.model_texture(&state.dragon),
		state.sampler,
	)

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

	state.skybox = defaults.skybox_create(gfx, SKYBOX_PATH)

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
	defaults.skybox_add_to_scene(&state.scene, &state.skybox)
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
	// Dragons stand behind the fleet, independent of the per-model count.
	for index in 0 ..< DRAGON_COUNT {
		x := (f32(index) - 1) * 110
		scale := f32(DRAGON_SCALE)
		gbbfx.scene_add_model(
			&state.scene,
			&state.dragon,
			{x, 0, -270},
			{scale, scale, scale},
			linalg.quaternion_from_euler_angles_f32(0, f32(index) * 0.6, 0, .XYZ),
		)
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

	fly_camera_tick(&state.fly_camera, gfx, delta_time)

	// HUD text.
	clear(&state.text_vertices)
	fps_buffer: [32]byte
	benchmark_push_text(
		state,
		gfx,
		fmt.bprintf(fps_buffer[:], "%.0f FPS", 1 / delta_time),
		10,
		10,
		{1, 1, 1, 1},
	)
	count_buffer: [32]byte
	benchmark_push_text(
		state,
		gfx,
		fmt.bprintf(count_buffer[:], "objects: %d", state.per_model * BOAT_COUNT + DRAGON_COUNT),
		10,
		30,
		{1, 1, 1, 1},
	)
	draws_buffer: [32]byte
	benchmark_push_text(
		state,
		gfx,
		fmt.bprintf(draws_buffer[:], "draws: %d", gfx.renderer.draw_calls),
		10,
		50,
		{1, 1, 1, 1},
	)
	benchmark_push_text(
		state,
		gfx,
		"=/- objects  wasd move  shift fast",
		10,
		70,
		gbbfx.color_srgb_to_linear({0.8, 0.8, 0.8, 1}),
	)
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
		sdl.BindGPUVertexBuffers(
			pass,
			0,
			&(sdl.GPUBufferBinding{buffer = vertex_buffer.handle}),
			1,
		)
		sdl.DrawGPUPrimitives(pass, u32(len(state.text_vertices)), 1, 0, 0)
		gbbfx.renderer_end_pass(renderer)
		gbbfx.renderer_present(renderer, renderer.scene_color)
	}
	gbbfx.gfx_end_frame(gfx)
}

benchmark_destroy :: proc(demo: ^Scene, gfx: ^gbbfx.Gfx) {
	state := cast(^Benchmark_State)demo.state
	gbbfx.scene_destroy(&state.scene)
	defaults.skybox_destroy(gfx, &state.skybox)
	delete(state.text_vertices)
	gbbfx.mesh_destroy(gfx, &state.text_mesh)
	gbbfx.material_destroy(&state.overlay_material)
	gbbfx.gfx_pipeline_destroy(gfx, state.overlay_pipeline)
	gbbfx.font_destroy(gfx, &state.font)
	for &model in state.models do gbbfx.gfx_unload(gfx, &model)
	gbbfx.gfx_unload(gfx, &state.dragon)
	gbbfx.gfx_sampler_destroy(gfx, state.sampler)
	gbbfx.gfx_pipeline_destroy(gfx, state.pipeline)
	free(state)
}
