// Benchmark: N instances of each boat model plus a few huge Stanford dragons, with on-screen text
// (FPS, object count, controls) drawn through the gfx font renderer.
// = / - add and remove instances.
package benchmark

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import gfx "../../engine/gfx"
import default "../../engine/default"
import input "../../engine/input"
import shader_parameters "../../shader_parameters"
import sdl "vendor:sdl3"
import engine "../../engine"

BENCH_STEP :: 10 // per boat model, per keypress

BOAT_PATHS :: [?]string {
	"static/models/sea/boat-fan.glb",
	"static/models/sea/boat-fishing-small.glb",
	"static/models/sea/boat-house-a.glb",
	"static/models/sea/boat-house-b.glb",
	"static/models/sea/boat-house-c.glb",
	"static/models/sea/boat-house-d.glb",
	"static/models/sea/boat-row-large.glb",
	"static/models/sea/boat-row-small.glb",
	"static/models/sea/boat-sail-a.glb",
	"static/models/sea/boat-sail-b.glb",
	"static/models/sea/boat-speed-a.glb",
	"static/models/sea/boat-speed-b.glb",
	"static/models/sea/boat-speed-c.glb",
	"static/models/sea/boat-speed-d.glb",
	"static/models/sea/boat-speed-e.glb",
	"static/models/sea/boat-speed-f.glb",
	"static/models/sea/boat-speed-g.glb",
	"static/models/sea/boat-speed-h.glb",
	"static/models/sea/boat-speed-i.glb",
	"static/models/sea/boat-speed-j.glb",
	"static/models/sea/boat-tow-a.glb",
	"static/models/sea/boat-tow-b.glb",
	"static/models/sea/boat-tug-a.glb",
	"static/models/sea/boat-tug-b.glb",
	"static/models/sea/boat-tug-c.glb",
	"static/models/sea/ship-cargo-a.glb",
	"static/models/sea/ship-cargo-b.glb",
	"static/models/sea/ship-cargo-c.glb",
	"static/models/sea/ship-large.glb",
	"static/models/sea/ship-ocean-liner.glb",
	"static/models/sea/ship-ocean-liner-small.glb",
	"static/models/sea/ship-small.glb",
	"static/models/sea/ship-small-ghost.glb",
}
BOAT_COUNT :: len(BOAT_PATHS)

// Dragon mesh is ~140 units long (boats are 3-20): scaled up it towers over
// the fleet. 58k vertices each; one instanced draw for all of them.
DRAGON_PATH :: "static/models/sea/stanford_dragon_pbr.glb"
DRAGON_COUNT :: 12
DRAGON_SCALE :: 0.6
DRAGON_RING_RADIUS :: 450
FLEET_CENTER_Z :: -135 // middle of the boat spawn area in benchmark_populate

// Flat unlit sea, far larger than the view so its edge never shows at the horizon.
SEA_HALF :: 2000
SEA_Y :: -0.6
SEA_CELLS :: 400 // 10-unit cells: coarser aliases the 32-unit waves the mesh displaces
FOG_VIEW_DISTANCE :: 700
BOAT_DRAFT :: 0.1 // boat origin height above sea level at rest

// Boat rest position in x/z and yaw; tick sets its height and tilt from the sea.
Boat_Slot :: struct {
	draw:  int,
	x, z:  f32,
	yaw:   linalg.Quaternionf32,
	scale: f32,
}

Benchmark_State :: struct {
	pipeline:         gfx.Pipeline_Handle,
	sampler:          gfx.Sampler_Handle,
	models:           [BOAT_COUNT]gfx.Model,
	dragon:           gfx.Model,
	draws:            [dynamic]gfx.Draw,
	skybox:           default.Skybox,
	sea_pipeline:     gfx.Pipeline_Handle,
	sea_material:     gfx.Material,
	sea_mesh:         gfx.Mesh,
	sea_time:         f32,
	boats:            [dynamic]Boat_Slot,
	per_model:        int,
	font:             gfx.Font,
	overlay_pipeline: gfx.Pipeline_Handle,
	overlay_material: gfx.Material,
	text_mesh:        gfx.Mesh,
	text_vertices:    [dynamic]gfx.VertexData,
	fly_camera:       default.Fly_Camera,
	add_action:       input.Button_Action,
	subtract_action:  input.Button_Action,
	fog_action:       input.Button_Action,
	hud_time:         f32,
	hud_frames:       int,
	hud_fps:          f32,
	hud_draws:        int,
	fog_on:           bool,
}

benchmark_scene :: proc() -> engine.Scene {
	return {
		name = "Benchmark",
		create = benchmark_create,
		tick = benchmark_tick,
		destroy = benchmark_destroy,
	}
}

benchmark_create :: proc(demo: ^engine.Scene, ctx: ^engine.Context) -> bool {
	dev := &ctx.gfx
	state := new(Benchmark_State)
	state.fog_on = true // haze by default so boats and dragons share the sea's horizon blend
	demo.state = state
	engine.scene_camera_reset(demo, dev, {0, 8, 20})
	// Uncapped: the point of this scene is measuring real frame cost.
	gfx.set_present_mode(dev, .IMMEDIATE)

	inputs := &ctx.input
	state.fly_camera = default.fly_camera_create(dev, &ctx.input, "benchmark")
	state.add_action = input.button(inputs, "benchmark.add")
	state.subtract_action = input.button(inputs, "benchmark.subtract")
	input.bind_key(inputs, state.add_action, .EQUALS)
	input.bind_key(inputs, state.subtract_action, .MINUS)
	state.fog_action = input.button(inputs, "benchmark.fog")
	input.bind_key(inputs, state.fog_action, .V)

	state.pipeline = default.create_textured_instanced_pipeline(dev)
	state.sampler = gfx.sampler_create(dev, gfx.SAMPLER_TRILINEAR)
	boat_paths := BOAT_PATHS
	for path, index in boat_paths {
		state.models[index] = gfx.model_load(dev, {model_path = path, pipeline = state.pipeline})
		default.bind_textured_instanced_material(
			&state.models[index].material,
			gfx.model_texture(&state.models[index]),
			state.sampler,
		)
	}
	state.dragon = gfx.model_load(dev, {model_path = DRAGON_PATH, pipeline = state.pipeline})
	default.bind_textured_instanced_material(
		&state.dragon.material,
		gfx.model_texture(&state.dragon),
		state.sampler,
	)

	// On-screen text: font atlas + blended depth-less overlay pipeline.
	font, font_ok := gfx.font_create(dev, "static/fonts/andale-mono.ttf")
	assert(font_ok)
	state.font = font
	state.overlay_pipeline = default.create_textured_overlay_pipeline(dev)
	state.overlay_material = gfx.material_create(state.overlay_pipeline)
	default.bind_textured_material(&state.overlay_material, state.font.texture, state.sampler)
	dummy := [6]gfx.VertexData{}
	state.text_mesh = gfx.mesh_create_unindexed(dev, dummy[:])
	gfx.mesh_upload(&dev.renderer, &state.text_mesh)

	state.skybox = default.skybox_create(dev, default.SKYBOX_PATH)
	state.sea_pipeline = sea_pipeline_create(dev, state)
	state.sea_material = gfx.material_create(state.sea_pipeline)
	state.sea_mesh = sea_mesh_create(dev)

	rand.reset(1) // fixed layout: every run draws the same fleet, so results compare
	benchmark_populate(state, 150)
	return true
}

// Rebuilds the draw list at a new per-model instance count. Models stay
// loaded; only the draws are recreated.
benchmark_populate :: proc(state: ^Benchmark_State, per_model: int) {
	state.per_model = per_model
	clear(&state.draws)
	clear(&state.boats)
	append(&state.draws, default.skybox_draw(&state.skybox))
	append(&state.draws, gfx.draw_make(&state.sea_mesh, &state.sea_material, layer = .WORLD))
	for &model in state.models {
		for _ in 0 ..< per_model {
			position := gfx.Vec3 {
				rand.float32_range(-700, 700),
				-0.5,
				rand.float32_range(-650, -20),
			}
			yaw := linalg.quaternion_from_euler_angles_f32(
				0,
				rand.float32_range(0, linalg.TAU),
				0,
				.XYZ,
			)
			scale := 0.25 + rand.float32_range(0, 0.2)
			if rand.float32() < 0.12 do scale *= rand.float32_range(2, 4) // a few big ships among the small boats
			append(&state.draws, gfx.draw_model(&model, position, {scale, scale, scale}, yaw))
			append(&state.boats, Boat_Slot{draw = len(state.draws) - 1, x = position.x, z = position.z, yaw = yaw, scale = scale})
		}
	}
	// Dragons ring the fleet, facing its centre, independent of the per-model count.
	for index in 0 ..< DRAGON_COUNT {
		angle := f32(index) / DRAGON_COUNT * linalg.TAU
		scale := f32(DRAGON_SCALE)
		append(
			&state.draws,
			gfx.draw_model(
				&state.dragon,
				{math.cos(angle) * DRAGON_RING_RADIUS, 0, FLEET_CENTER_Z + math.sin(angle) * DRAGON_RING_RADIUS},
				{scale, scale, scale},
				linalg.quaternion_from_euler_angles_f32(0, -angle - linalg.PI / 2, 0, .XYZ),
			),
		)
	}
}

bench_to_ndc :: proc(x, y, width, height: f32) -> [3]f32 {
	return {x / width * 2 - 1, 1 - y / height * 2, 0}
}

benchmark_push_text :: proc(
	state: ^Benchmark_State,
	dev: ^gfx.Device,
	text: string,
	x, top: f32,
	color: [4]f32,
) {
	cursor_x := x
	cursor_y := top + f32(state.font.baseline)
	quads: [dynamic]gfx.Font_Quad
	defer delete(quads)
	gfx.font_layout(&state.font, text, &cursor_x, &cursor_y, &quads)
	width := f32(dev.window_size.x)
	height := f32(dev.window_size.y)
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
			gfx.VertexData{position = p0, color = color, uv = uv0},
			gfx.VertexData{position = p1, color = color, uv = uv1},
			gfx.VertexData{position = p2, color = color, uv = uv2},
			gfx.VertexData{position = p0, color = color, uv = uv0},
			gfx.VertexData{position = p2, color = color, uv = uv2},
			gfx.VertexData{position = p3, color = color, uv = uv3},
		)
	}
}

sea_mesh_create :: proc(dev: ^gfx.Device) -> gfx.Mesh {
	n :: SEA_CELLS + 1
	cell :: f32(2 * SEA_HALF) / SEA_CELLS
	vertices := make([dynamic]gfx.VertexData, 0, n * n, context.temp_allocator)
	for z in 0 ..< n {
		for x in 0 ..< n {
			position := gfx.Vec3{-SEA_HALF + f32(x) * cell, SEA_Y, -SEA_HALF + f32(z) * cell}
			append(&vertices, gfx.VertexData{position = position})
		}
	}
	indices := make([dynamic]u32, 0, SEA_CELLS * SEA_CELLS * 6, context.temp_allocator)
	stride := u32(n)
	for z in 0 ..< SEA_CELLS {
		for x in 0 ..< SEA_CELLS {
			i := u32(z * n + x)
			append(&indices, i, i + stride, i + 1, i + 1, i + stride, i + stride + 1)
		}
	}
	mesh := gfx.mesh_create(dev, vertices[:], indices[:])
	gfx.mesh_upload(&dev.renderer, &mesh)
	return mesh
}

sea_pipeline_create :: proc(dev: ^gfx.Device, state: ^Benchmark_State) -> gfx.Pipeline_Handle {
	attributes := shader_parameters.sea_vertex_attributes(gfx.VertexData)
	return gfx.pipeline_create(
		dev,
		{
			vertex = shader_parameters.sea_vertex(),
			fragment = shader_parameters.sea_fragment(),
			vertex_attributes = attributes[:],
			vertex_stride = u32(size_of(gfx.VertexData)),
			depth_test = true,
			depth_write = true,
			cull_mode = .BACK,
			bind_draw = sea_bind_draw,
			user_data = state,
		},
	)
}

// Pushes per-draw transforms and the time the wave field advances on.
sea_bind_draw :: proc(
	user_data: rawptr,
	draw_context: ^gfx.Draw_Context,
	parameters: gfx.Draw_Parameters,
) {
	state := cast(^Benchmark_State)user_data
	camera := parameters.camera_position
	uniforms := shader_parameters.SeaVertexUniformBlock {
		data = {
			mvp = parameters.view_projection * parameters.model_transform,
			model = parameters.model_transform,
			camera_position = {camera.x, camera.y, camera.z, 1},
			time = {state.sea_time, 0, 0, 0},
			fog = parameters.fog,
		},
	}
	gfx.draw_push_uniform(draw_context, shader_parameters.SEA_VERTEX_UNIFORM_BLOCK, &uniforms)
}

benchmark_tick :: proc(demo: ^engine.Scene, ctx: ^engine.Context, delta_time: f32) {
	dev := &ctx.gfx
	state := cast(^Benchmark_State)demo.state

	inputs := &ctx.input
	if input.pressed(inputs, state.add_action) {
		benchmark_populate(state, state.per_model + BENCH_STEP)
	}
	if input.pressed(inputs, state.subtract_action) && state.per_model >= BENCH_STEP {
		benchmark_populate(state, state.per_model - BENCH_STEP)
	}
	if input.pressed(inputs, state.fog_action) {
		state.fog_on = !state.fog_on
	}
	fog_rgb := gfx.color_srgb_to_linear({0.671, 0.757, 0.949, 1}) // skybox horizon; matches `sky` in sea.slang
	dev.renderer.fog = state.fog_on ? {fog_rgb.r, fog_rgb.g, fog_rgb.b, FOG_VIEW_DISTANCE} : [4]f32{}

	default.fly_camera_tick(&state.fly_camera, dev, &ctx.input, delta_time)
	state.sea_time += delta_time
	camera := dev.renderer.camera.position
	for boat in state.boats {
		flat := gfx.Vec3{boat.x, SEA_Y, boat.z}
		h, grad := sea_surface_height(flat.xz, state.sea_time, linalg.distance(camera, flat))
		normal := linalg.normalize(gfx.Vec3{-grad.x, 1, -grad.y})
		tilt := linalg.quaternion_angle_axis_f32(
			math.acos(clamp(normal.y, -1, 1)),
			linalg.normalize0(linalg.cross(gfx.Vec3{0, 1, 0}, normal)),
		)
		gfx.draw_set_transform(
			&state.draws[boat.draw],
			{boat.x, SEA_Y + h + BOAT_DRAFT, boat.z},
			tilt * boat.yaw,
			{boat.scale, boat.scale, boat.scale},
		)
	}

	// FPS and draws refresh once per second so the text stays readable.
	state.hud_time += delta_time
	state.hud_frames += 1
	if state.hud_time >= 1 || (state.hud_fps == 0 && state.hud_time > 0) {
		state.hud_fps = f32(state.hud_frames) / state.hud_time
		state.hud_draws = dev.renderer.draw_calls
		state.hud_time, state.hud_frames = 0, 0
	}

	// HUD text.
	clear(&state.text_vertices)
	fps_buffer: [32]byte
	benchmark_push_text(
		state,
		dev,
		fmt.bprintf(fps_buffer[:], "%.0f FPS", state.hud_fps),
		10,
		10,
		{1, 1, 1, 1},
	)
	count_buffer: [32]byte
	benchmark_push_text(
		state,
		dev,
		fmt.bprintf(count_buffer[:], "objects: %d", state.per_model * BOAT_COUNT + DRAGON_COUNT),
		10,
		30,
		{1, 1, 1, 1},
	)
	draws_buffer: [32]byte
	benchmark_push_text(
		state,
		dev,
		fmt.bprintf(draws_buffer[:], "draws: %d", state.hud_draws),
		10,
		50,
		{1, 1, 1, 1},
	)
	benchmark_push_text(
		state,
		dev,
		state.fog_on ? "fog + view distance on (V)" : "fog + view distance off (V)",
		10,
		90,
		{1, 1, 1, 1},
	)
	benchmark_push_text(
		state,
		dev,
		"=/- objects  wasd move  shift fast  c smooth cam",
		10,
		70,
		gfx.color_srgb_to_linear({0.8, 0.8, 0.8, 1}),
	)
	gfx.mesh_update_unindexed(&dev.renderer, &state.text_mesh, state.text_vertices[:])

	// Frame flow: scene -> offscreen, text into the offscreen, blit out.
	gfx.renderer_begin_frame(&dev.renderer)
	gfx.renderer_render_draws(&dev.renderer, state.draws[:])
	if dev.swapchain != nil {
		renderer := &dev.renderer
		gfx.renderer_begin_overlay_pass(renderer, renderer.scene_color)
		pass := renderer.pass
		pipeline := gfx.pipeline_get(dev, state.overlay_pipeline)
		sdl.BindGPUGraphicsPipeline(pass, pipeline.handle)
		gfx.pipeline_bind_material(dev, pass, dev.command_buffer, &state.overlay_material)
		gfx.pipeline_bind_draw(
			dev,
			state.overlay_pipeline,
			dev.command_buffer,
			{
				view_projection = linalg.MATRIX4F32_IDENTITY,
				model_transform = linalg.MATRIX4F32_IDENTITY,
				material = &state.overlay_material,
			},
		)
		vertex_buffer := gfx.buffer_get(dev, state.text_mesh.vertex_buffer)
		sdl.BindGPUVertexBuffers(
			pass,
			0,
			&(sdl.GPUBufferBinding{buffer = vertex_buffer.handle}),
			1,
		)
		sdl.DrawGPUPrimitives(pass, u32(len(state.text_vertices)), 1, 0, 0)
		gfx.renderer_end_pass(renderer)
		gfx.renderer_present(renderer, gfx.renderer_run_post(renderer)) // run_post: global overlays (F1 stats)
	}
	gfx.end_frame(dev)
}

benchmark_destroy :: proc(demo: ^engine.Scene, ctx: ^engine.Context) {
	dev := &ctx.gfx
	state := cast(^Benchmark_State)demo.state
	delete(state.draws)
	default.skybox_destroy(dev, &state.skybox)
	gfx.mesh_destroy(dev, &state.sea_mesh)
	gfx.material_destroy(&state.sea_material)
	gfx.pipeline_destroy(dev, state.sea_pipeline)
	delete(state.text_vertices)
	gfx.mesh_destroy(dev, &state.text_mesh)
	gfx.material_destroy(&state.overlay_material)
	gfx.pipeline_destroy(dev, state.overlay_pipeline)
	gfx.font_destroy(dev, &state.font)
	for &model in state.models do gfx.model_unload(dev, &model)
	gfx.model_unload(dev, &state.dragon)
	gfx.sampler_destroy(dev, state.sampler)
	gfx.pipeline_destroy(dev, state.pipeline)
	free(state)
}
