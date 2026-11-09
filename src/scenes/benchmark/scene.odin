// Benchmark: N instances of each boat model plus a few huge Stanford dragons, with on-screen text
// (FPS, object count, controls) drawn through the gbbfx font renderer.
// = / - add and remove instances.
package benchmark

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import gbbfx "../../gbbfx"
import defaults "../../gbbfx/defaults"
import glove "../../glove"
import scenekit "../../scenekit"
import shader_parameters "../../shader_parameters"
import sdl "vendor:sdl3"

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
	entity: int,
	x, z:   f32,
	yaw:    linalg.Quaternionf32,
}

Benchmark_State :: struct {
	pipeline:         gbbfx.Pipeline_Handle,
	sampler:          gbbfx.Sampler_Handle,
	models:           [BOAT_COUNT]gbbfx.Model,
	dragon:           gbbfx.Model,
	scene:            gbbfx.Scene,
	skybox:           defaults.Skybox,
	sea_pipeline:     gbbfx.Pipeline_Handle,
	sea_material:     gbbfx.Material,
	sea_mesh:         gbbfx.Mesh,
	sea_time:         f32,
	boats:            [dynamic]Boat_Slot,
	per_model:        int,
	font:             gbbfx.Font,
	overlay_pipeline: gbbfx.Pipeline_Handle,
	overlay_material: gbbfx.Material,
	text_mesh:        gbbfx.Mesh,
	text_vertices:    [dynamic]gbbfx.VertexData,
	fly_camera:       scenekit.FlyCamera,
	add_action:       glove.Button_Action,
	subtract_action:  glove.Button_Action,
	fog_action:       glove.Button_Action,
	hud_time:         f32,
	hud_frames:       int,
	hud_fps:          f32,
	hud_draws:        int,
	fog_on:           bool,
}

benchmark_scene :: proc() -> scenekit.Scene {
	return {
		name = "Benchmark",
		create = benchmark_create,
		tick = benchmark_tick,
		destroy = benchmark_destroy,
	}
}

benchmark_create :: proc(demo: ^scenekit.Scene, gfx: ^gbbfx.Gfx) -> bool {
	state := new(Benchmark_State)
	state.fog_on = true // haze by default so boats and dragons share the sea's horizon blend
	demo.state = state
	scenekit.camera_reset(gfx, {0, 8, 20})
	// Uncapped: the point of this scene is measuring real frame cost.
	gbbfx.gfx_set_present_mode(gfx, .IMMEDIATE)

	inputs := gbbfx.gfx_input(gfx)
	state.fly_camera = scenekit.fly_camera_create(gfx, "benchmark")
	state.add_action = glove.add_button(inputs, "benchmark.add")
	state.subtract_action = glove.add_button(inputs, "benchmark.subtract")
	glove.bind_key(inputs, state.add_action, .EQUALS)
	glove.bind_key(inputs, state.subtract_action, .MINUS)
	state.fog_action = glove.add_button(inputs, "benchmark.fog")
	glove.bind_key(inputs, state.fog_action, .V)

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

	state.skybox = defaults.skybox_create(gfx, scenekit.SKYBOX_PATH)
	state.sea_pipeline = sea_pipeline_create(gfx, state)
	state.sea_material = gbbfx.material_create(state.sea_pipeline)
	state.sea_mesh = sea_mesh_create(gfx)

	rand.reset(1) // fixed layout: every run draws the same fleet, so results compare
	benchmark_populate(state, 150)
	return true
}

// Rebuilds the entity list at a new per-model instance count. Models stay
// loaded; only scene entities are recreated.
benchmark_populate :: proc(state: ^Benchmark_State, per_model: int) {
	state.per_model = per_model
	gbbfx.scene_destroy(&state.scene)
	state.scene = {}
	clear(&state.boats)
	defaults.skybox_add_to_scene(&state.scene, &state.skybox)
	sea := gbbfx.scene_add_entity(&state.scene)
	gbbfx.entity_add_renderable(
		gbbfx.scene_entity(&state.scene, sea),
		&state.sea_mesh,
		&state.sea_material,
		.WORLD,
	)
	for &model in state.models {
		for _ in 0 ..< per_model {
			position := gbbfx.Vec3 {
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
			index := gbbfx.scene_add_model(&state.scene, &model, position, {scale, scale, scale}, yaw)
			append(&state.boats, Boat_Slot{entity = index, x = position.x, z = position.z, yaw = yaw})
		}
	}
	// Dragons ring the fleet, facing its centre, independent of the per-model count.
	for index in 0 ..< DRAGON_COUNT {
		angle := f32(index) / DRAGON_COUNT * linalg.TAU
		scale := f32(DRAGON_SCALE)
		gbbfx.scene_add_model(
			&state.scene,
			&state.dragon,
			{math.cos(angle) * DRAGON_RING_RADIUS, 0, FLEET_CENTER_Z + math.sin(angle) * DRAGON_RING_RADIUS},
			{scale, scale, scale},
			linalg.quaternion_from_euler_angles_f32(0, -angle - linalg.PI / 2, 0, .XYZ),
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

sea_mesh_create :: proc(gfx: ^gbbfx.Gfx) -> gbbfx.Mesh {
	n :: SEA_CELLS + 1
	cell :: f32(2 * SEA_HALF) / SEA_CELLS
	vertices := make([dynamic]gbbfx.VertexData, 0, n * n, context.temp_allocator)
	for z in 0 ..< n {
		for x in 0 ..< n {
			position := gbbfx.Vec3{-SEA_HALF + f32(x) * cell, SEA_Y, -SEA_HALF + f32(z) * cell}
			append(&vertices, gbbfx.VertexData{position = position})
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
	mesh := gbbfx.mesh_create(gfx, vertices[:], indices[:])
	gbbfx.mesh_upload(&gfx.renderer, &mesh)
	return mesh
}

sea_pipeline_create :: proc(gfx: ^gbbfx.Gfx, state: ^Benchmark_State) -> gbbfx.Pipeline_Handle {
	attributes := shader_parameters.sea_vertex_attributes(gbbfx.VertexData)
	return gbbfx.gfx_pipeline_create(
		gfx,
		{
			vertex = shader_parameters.sea_vertex(),
			fragment = shader_parameters.sea_fragment(),
			vertex_attributes = attributes[:],
			vertex_stride = u32(size_of(gbbfx.VertexData)),
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
	draw_context: ^gbbfx.Draw_Context,
	parameters: gbbfx.Draw_Parameters,
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
	gbbfx.draw_push_uniform(draw_context, shader_parameters.SEA_VERTEX_UNIFORM_BLOCK, &uniforms)
}

benchmark_tick :: proc(demo: ^scenekit.Scene, gfx: ^gbbfx.Gfx, delta_time: f32) {
	state := cast(^Benchmark_State)demo.state

	inputs := gbbfx.gfx_input(gfx)
	if glove.pressed(inputs, state.add_action) {
		benchmark_populate(state, state.per_model + BENCH_STEP)
	}
	if glove.pressed(inputs, state.subtract_action) && state.per_model >= BENCH_STEP {
		benchmark_populate(state, state.per_model - BENCH_STEP)
	}
	if glove.pressed(inputs, state.fog_action) {
		state.fog_on = !state.fog_on
	}
	fog_rgb := gbbfx.color_srgb_to_linear({0.671, 0.757, 0.949, 1}) // skybox horizon; matches `sky` in sea.slang
	gfx.renderer.fog = state.fog_on ? {fog_rgb.r, fog_rgb.g, fog_rgb.b, FOG_VIEW_DISTANCE} : [4]f32{}

	scenekit.fly_camera_tick(&state.fly_camera, gfx, delta_time)
	state.sea_time += delta_time
	camera := gfx.renderer.camera.position
	for boat in state.boats {
		flat := gbbfx.Vec3{boat.x, SEA_Y, boat.z}
		h, grad := sea_surface_height(flat.xz, state.sea_time, linalg.distance(camera, flat))
		normal := linalg.normalize(gbbfx.Vec3{-grad.x, 1, -grad.y})
		gbbfx.entity_set_position(
			gbbfx.scene_entity(&state.scene, boat.entity),
			{boat.x, SEA_Y + h + BOAT_DRAFT, boat.z},
		)
		tilt := linalg.quaternion_angle_axis_f32(
			math.acos(clamp(normal.y, -1, 1)),
			linalg.normalize0(linalg.cross(gbbfx.Vec3{0, 1, 0}, normal)),
		)
		gbbfx.entity_set_rotation(gbbfx.scene_entity(&state.scene, boat.entity), tilt * boat.yaw)
	}

	// FPS and draws refresh once per second so the text stays readable.
	state.hud_time += delta_time
	state.hud_frames += 1
	if state.hud_time >= 1 || (state.hud_fps == 0 && state.hud_time > 0) {
		state.hud_fps = f32(state.hud_frames) / state.hud_time
		state.hud_draws = gfx.renderer.draw_calls
		state.hud_time, state.hud_frames = 0, 0
	}

	// HUD text.
	clear(&state.text_vertices)
	fps_buffer: [32]byte
	benchmark_push_text(
		state,
		gfx,
		fmt.bprintf(fps_buffer[:], "%.0f FPS", state.hud_fps),
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
		fmt.bprintf(draws_buffer[:], "draws: %d", state.hud_draws),
		10,
		50,
		{1, 1, 1, 1},
	)
	benchmark_push_text(
		state,
		gfx,
		state.fog_on ? "fog + view distance on (V)" : "fog + view distance off (V)",
		10,
		90,
		{1, 1, 1, 1},
	)
	benchmark_push_text(
		state,
		gfx,
		"=/- objects  wasd move  shift fast  c smooth cam",
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

benchmark_destroy :: proc(demo: ^scenekit.Scene, gfx: ^gbbfx.Gfx) {
	state := cast(^Benchmark_State)demo.state
	gbbfx.scene_destroy(&state.scene)
	defaults.skybox_destroy(gfx, &state.skybox)
	gbbfx.mesh_destroy(gfx, &state.sea_mesh)
	gbbfx.material_destroy(&state.sea_material)
	gbbfx.gfx_pipeline_destroy(gfx, state.sea_pipeline)
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
