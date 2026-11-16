// Forest: stylised BotW-like meadow. The world is 16x16 chunks; each chunk is
// baked once into world-space meshes (terrain+trees, grass at two LODs) and
// streamed in as the camera approaches. Wind and toon shading run entirely in
// shaders/forest.slang, so a frame costs one draw per visible chunk mesh.
package forest_naive

import "core:math"
import "core:slice"
import gfx "../../engine/gfx"
import default "../../engine/default"
import input "../../engine/input"
import shader_parameters "../../shader_parameters"
import engine "../../engine"
import jobs "../../engine/jobs"

SUN_DIRECTION :: [3]f32{-0.559, 0.764, 0.322} // unit; measured by aiming the crosshair at the skybox sun (F1 `look`)
FOG_DISTANCE :: 560.0 // also the renderer's view distance: farther chunks are culled
BUILD_RADIUS :: FOG_DISTANCE + 12.0
GRASS_NEAR :: 42.0 // dense grass inside; hysteresis keeps LOD from flickering
GRASS_FAR :: 52.0
GRASS_MAX :: 95.0 // no grass past this; the terrain colour carries the meadow
BUILD_PER_FRAME :: 6 // chunk meshes baked per tick once streaming
BUILD_IN_FLIGHT :: 8 // chunk bakes running on the job pool at once
START_RADIUS :: 140.0 // baked before the first frame; the rest streams in under fog
FOG_COLOR :: [3]f32{0.62, 0.78, 0.95}
SHADOW_BIAS :: 0.0005 // receiver depth bias in shadow-map [0,1] units (~0.15 m over SHADOW_DEPTH); casters add hardware slope bias

Mesh_Data :: struct {
	verts: [dynamic]gfx.VertexData,
	idx:   [dynamic]u16,
}

// Mesh keeps slices into Mesh_Data, so both live until destroy.
Chunk :: struct {
	static_job:   Build,
	static_data:  Mesh_Data,
	static_mesh:  gfx.Mesh,
	grass_entity: int, // -1 until the first grass mesh exists
	grass_lod:    int,
	grass_job:    [2]Build,
	grass_data:   [2]Mesh_Data,
	grass_mesh:   [2]gfx.Mesh,
}

// One async bake. The job fills mesh.verts and indices (context.allocator); the main
// thread uploads them in finish and frees indices. mesh points into the chunk, which never moves.
Build :: struct {
	state:   enum { Empty, Building, Built },
	group:   jobs.Group,
	cx, cz:  int,
	lod:     int, // grass only
	mesh:    ^Mesh_Data,
	indices: [dynamic]u32,
}

Forest_State :: struct {
	pipeline:   gfx.Pipeline_Handle,
	material:   gfx.Material,
	bloom:      gfx.Bloom,
	chunks:     [CHUNKS_PER_SIDE * CHUNKS_PER_SIDE]Chunk,
	time:       f32,
	shadow_action: input.Button_Action, // H: toggles renderer.shadow_enabled
	flare:      Flare,
	crosshair:  Crosshair, // C: toggles the screen-centre cross
	physics:    Physics,
	ball_action: input.Button_Action, // B: launches a ball from the camera
}

forest_naive_scene :: proc() -> engine.Scene {
	return {name = "Forest (naive)", create = forest_create, tick = forest_tick, fixed_tick = forest_fixed_tick, destroy = forest_destroy}
}

forest_create :: proc(demo: ^engine.Scene, ctx: ^engine.Context) -> bool {
	gfx_ctx := &ctx.gfx
	state := new(Forest_State)
	demo.state = state
	for &chunk in state.chunks do chunk.grass_entity = -1
	engine.camera_fly(ctx, {0, terrain_height(0, 0) + 2.5, 0}, {0, terrain_height(0, -10) + 2, -10})

	attributes := shader_parameters.forest_vertex_attributes(gfx.VertexData)
	state.pipeline = gfx.pipeline_create(
		gfx_ctx,
		{
			vertex = shader_parameters.forest_vertex(),
			fragment = shader_parameters.forest_fragment(),
			vertex_attributes = attributes[:],
			vertex_stride = u32(size_of(gfx.VertexData)),
			depth_test = true,
			depth_write = true,
			cull_mode = .NONE, // grass is two-sided; closed meshes are depth-rejected anyway
			bind_draw = forest_bind_draw,
			user_data = state,
		},
	)
	state.material = gfx.material_make(state.pipeline)
	gfx.material_bind_texture(&state.material, shader_parameters.FOREST_FRAGMENT_SHADOW_MAP, shader_parameters.FOREST_FRAGMENT_SHADOW_SAMPLER, gfx_ctx.renderer.shadow_map, gfx_ctx.renderer.shadow_sampler)
	gfx_ctx.renderer.light_direction = SUN_DIRECTION
	state.shadow_action = input.button(&ctx.input, "forest.shadows", .H, "Toggle shadows")
	state.ball_action = input.button(&ctx.input, "forest_naive.ball", .B, "Launch ball")
	physics_create(&state.physics, gfx_ctx, &state.material, .Mesh)

	gfx.skybox_add(gfx_ctx, default.SKYBOX_PATH)

	state.bloom = gfx.bloom_create(gfx_ctx, 0.95, 0.2, 5)
	gfx.renderer_set_passes(&gfx_ctx.renderer, .Post, []gfx.Render_Pass{gfx.bloom_pass(&state.bloom)})
	flare_create(gfx_ctx, &state.flare)
	crosshair_create(gfx_ctx, &state.crosshair, input.button(&ctx.input, "forest.crosshair", .C, "Toggle crosshair")) // after flare: flare resets After_Scene
	showcase_create(gfx_ctx)

	forest_stream(state, gfx_ctx, &ctx.jobs, 1 << 20, START_RADIUS, true)
	return true
}

// Passes the time wind runs on; the shader gets the entity model matrix so
// meshes can be stored relative to their chunk origin (tight culling bounds).
forest_bind_draw :: proc(
	user_data: rawptr,
	draw_context: ^gfx.Draw_Context,
	parameters: gfx.Draw_Parameters,
) {
	state := cast(^Forest_State)user_data
	camera := parameters.camera_position
	uniforms := shader_parameters.ForestVertexUniformBlock {
		data = {
			view_projection = parameters.view_projection,
			model = parameters.model_transform,
			camera_position = {camera.x, camera.y, camera.z, 1},
			time = {state.time, SUN_DIRECTION.x, SUN_DIRECTION.y, SUN_DIRECTION.z}, // yzw: sun for lighting and fog tint
			fog = parameters.fog,
			light_view_projection = parameters.light_view_projection,
			shadow_params = {parameters.shadow_enabled ? f32(1) : f32(0), SHADOW_BIAS, 1.0 / gfx.SHADOW_MAP_SIZE, 0},
		},
	}
	gfx.draw_push_uniform(draw_context, shader_parameters.FOREST_VERTEX_UNIFORM_BLOCK, &uniforms)
}

forest_tick :: proc(demo: ^engine.Scene, ctx: ^engine.Context, delta_time: f32) {
	gfx_ctx := &ctx.gfx
	state := cast(^Forest_State)demo.state
	state.time += delta_time
	if input.pressed(&ctx.input, state.shadow_action) {
		gfx_ctx.renderer.shadow_enabled = !gfx_ctx.renderer.shadow_enabled
	}
	if input.pressed(&ctx.input, state.ball_action) do physics_launch(&state.physics, gfx_ctx)
	gfx_ctx.renderer.fog = {FOG_COLOR.r, FOG_COLOR.g, FOG_COLOR.b, FOG_DISTANCE}
	forest_stream(state, gfx_ctx, &ctx.jobs, BUILD_PER_FRAME, BUILD_RADIUS)
	flare_update(gfx_ctx, &state.flare, SUN_DIRECTION)
	crosshair_update(gfx_ctx, &state.crosshair, &ctx.input)
	physics_draw(&state.physics, gfx_ctx, ctx.blend)
	gfx.render(gfx_ctx)
}

forest_fixed_tick :: proc(demo: ^engine.Scene, ctx: ^engine.Context, delta_time: f32) {
	state := cast(^Forest_State)demo.state
	physics_step(&state.physics, delta_time)
}

// Chunk bakes run on the job pool; the main thread finishes them (upload, draw).
// Per tick: finish landed bakes (budget), apply each chunk's grass LOD once that LOD is
// built, then start the nearest Empty slots (at most BUILD_IN_FLIGHT in flight). `eager`
// starts every in-range bake, waits, and finishes them all (used once, at create).
// shortcut: built chunks are never freed, so flying the whole world holds
// ~400 MB of vertices; add eviction (with a GPU idle wait) if that matters.
forest_stream :: proc(state: ^Forest_State, gfx_ctx: ^gfx.Device, pool: ^jobs.Pool, budget: int, radius: f32, eager := false) {
	camera := gfx.camera(gfx_ctx).position
	limit := BUILD_IN_FLIGHT
	if eager {
		forest_start_builds(state, pool, camera, radius, max(int))
		forest_wait_builds(state, pool)
		limit = max(int)
	}
	forest_finish_builds(state, gfx_ctx, budget)
	forest_apply_grass(state, gfx_ctx, camera, radius)
	forest_start_builds(state, pool, camera, radius, limit)
}

// Distance is measured from the chunk centre; ox/oz is the chunk origin.
chunk_distance :: proc(index: int, camera: [3]f32) -> (ox, oz, distance: f32) {
	cx, cz := chunk_coords(index)
	ox, oz = chunk_origin(cx, cz)
	dx, dz := ox + CHUNK_SIZE / 2 - camera.x, oz + CHUNK_SIZE / 2 - camera.z
	distance = math.sqrt(dx * dx + dz * dz)
	return
}

chunk_coords :: proc(index: int) -> (cx, cz: int) {
	return index % CHUNKS_PER_SIDE, index / CHUNKS_PER_SIDE
}

grass_lod_for :: proc(chunk: ^Chunk, distance: f32) -> int {
	lod := chunk.grass_lod
	if chunk.grass_entity < 0 do lod = 1
	if distance < GRASS_NEAR do lod = 0
	if distance > GRASS_FAR do lod = 1
	return lod
}

// Starts bakes for the nearest Empty in-range slots until `limit` are in flight.
forest_start_builds :: proc(state: ^Forest_State, pool: ^jobs.Pool, camera: [3]f32, radius: f32, limit: int) {
	in_flight := 0
	for &chunk in state.chunks {
		if chunk.static_job.state == .Building do in_flight += 1
		for lod in 0 ..< 2 do if chunk.grass_job[lod].state == .Building do in_flight += 1
	}
	if in_flight >= limit do return

	Candidate :: struct {
		distance: f32,
		index:    int,
		lod:      int, // -1: static
	}
	candidates := make([dynamic]Candidate, context.temp_allocator)
	for index in 0 ..< len(state.chunks) {
		_, _, distance := chunk_distance(index, camera)
		if distance > radius do continue
		chunk := &state.chunks[index]
		if chunk.static_job.state == .Empty do append(&candidates, Candidate{distance, index, -1})
		if distance > GRASS_MAX do continue
		lod := grass_lod_for(chunk, distance)
		if chunk.grass_job[lod].state == .Empty do append(&candidates, Candidate{distance, index, lod})
	}
	slice.sort_by(candidates[:], proc(a, b: Candidate) -> bool { return a.distance < b.distance })

	for candidate in candidates {
		if in_flight >= limit do break
		in_flight += 1
		chunk := &state.chunks[candidate.index]
		cx, cz := chunk_coords(candidate.index)
		if candidate.lod < 0 {
			build_start(pool, &chunk.static_job, build_static_job, cx, cz, 0, &chunk.static_data)
		} else {
			build_start(pool, &chunk.grass_job[candidate.lod], build_grass_job, cx, cz, candidate.lod, &chunk.grass_data[candidate.lod])
		}
	}
}

build_start :: proc(pool: ^jobs.Pool, b: ^Build, fn: jobs.Job_Proc, cx, cz, lod: int, mesh: ^Mesh_Data) {
	b.state = .Building
	b.cx, b.cz, b.lod, b.mesh = cx, cz, lod, mesh
	jobs.run(pool, &b.group, fn, rawptr(b))
}

// Job procs: CPU only. Same calls, same order as the old main-thread bake.
build_static_job :: proc(data: rawptr) {
	b := cast(^Build)data
	terrain_chunk(b.cx, b.cz, &b.mesh.verts, &b.indices)
	trees_chunk(b.cx, b.cz, &b.mesh.verts, &b.indices, nil)
}

build_grass_job :: proc(data: rawptr) {
	b := cast(^Build)data
	grass_chunk(b.cx, b.cz, b.lod, &b.mesh.verts, &b.indices)
}

build_wait :: proc(pool: ^jobs.Pool, b: ^Build) {
	if b.state == .Building do jobs.wait(pool, &b.group)
}

forest_wait_builds :: proc(state: ^Forest_State, pool: ^jobs.Pool) {
	for &chunk in state.chunks {
		build_wait(pool, &chunk.static_job)
		for lod in 0 ..< 2 do build_wait(pool, &chunk.grass_job[lod])
	}
}

// Main thread: landed bakes become meshes and draws. Each finish costs one budget unit.
forest_finish_builds :: proc(state: ^Forest_State, gfx_ctx: ^gfx.Device, budget: int) {
	budget := budget
	for &chunk in state.chunks {
		if budget > 0 && chunk.static_job.state == .Building && jobs.done(&chunk.static_job.group) {
			budget -= 1
			forest_finish_static(state, gfx_ctx, &chunk)
		}
		for lod in 0 ..< 2 {
			build := &chunk.grass_job[lod]
			if budget > 0 && build.state == .Building && jobs.done(&build.group) {
				budget -= 1
				forest_finish_grass(gfx_ctx, &chunk, lod)
			}
		}
	}
}

forest_finish_static :: proc(state: ^Forest_State, gfx_ctx: ^gfx.Device, chunk: ^Chunk) {
	build := &chunk.static_job
	ox, oz := chunk_origin(build.cx, build.cz)
	chunk.static_mesh = forest_upload(gfx_ctx, &chunk.static_data, build.indices[:], ox, oz)
	delete(build.indices)
	build.indices = {}
	build.state = .Built
	gfx.draw_create(gfx_ctx, {mesh = &chunk.static_mesh, material = &state.material, position = {ox, 0, oz}})
}

forest_finish_grass :: proc(gfx_ctx: ^gfx.Device, chunk: ^Chunk, lod: int) {
	build := &chunk.grass_job[lod]
	ox, oz := chunk_origin(build.cx, build.cz)
	chunk.grass_mesh[lod] = forest_upload(gfx_ctx, &chunk.grass_data[lod], build.indices[:], ox, oz)
	delete(build.indices)
	build.indices = {}
	build.state = .Built
}

// Applies each chunk's wanted grass LOD once that LOD is Built; until then the
// current LOD keeps showing and the wanted one is re-checked next tick.
forest_apply_grass :: proc(state: ^Forest_State, gfx_ctx: ^gfx.Device, camera: [3]f32, radius: f32) {
	for index in 0 ..< len(state.chunks) {
		ox, oz, distance := chunk_distance(index, camera)
		if distance > radius do continue
		chunk := &state.chunks[index]
		if chunk.grass_entity >= 0 {
			// Out of range: hide the draw so it costs no fragments.
			gfx_ctx.draws[chunk.grass_entity].hidden = distance > GRASS_MAX
		}
		if distance > GRASS_MAX do continue
		lod := grass_lod_for(chunk, distance)
		if chunk.grass_entity >= 0 && lod == chunk.grass_lod do continue
		if chunk.grass_job[lod].state != .Built do continue
		chunk.grass_lod = lod
		if chunk.grass_entity < 0 {
			chunk.grass_entity = gfx.draw_create(gfx_ctx, {mesh = &chunk.grass_mesh[lod], material = &state.material, position = {ox, 0, oz}})
		} else {
			gfx_ctx.draws[chunk.grass_entity].mesh = &chunk.grass_mesh[lod]
		}
	}
}

// Moves world-space vertices to chunk-local x/z (so the mesh bound is centred
// near the entity), narrows indices to u16, and uploads.
forest_upload :: proc(gfx_ctx: ^gfx.Device, data: ^Mesh_Data, indices: []u32, ox, oz: f32) -> gfx.Mesh {
	assert(len(data.verts) < 1 << 16, "chunk mesh too large for u16 indices")
	for &vertex in data.verts {
		vertex.position.x -= ox
		vertex.position.z -= oz
	}
	if len(data.verts) == 0 { // SDL rejects 0-byte buffers: upload one degenerate (invisible) triangle
		resize(&data.verts, 3)
		resize(&data.idx, 3)
	} else {
		resize(&data.idx, len(indices))
		for index, i in indices do data.idx[i] = u16(index)
	}
	mesh := gfx.mesh_create(gfx_ctx, data.verts[:], data.idx[:])
	return mesh
}

forest_destroy :: proc(demo: ^engine.Scene, ctx: ^engine.Context) {
	gfx_ctx := &ctx.gfx
	state := cast(^Forest_State)demo.state
	gfx.renderer_clear_passes(&gfx_ctx.renderer, .Post)
	gfx.renderer_update_light(&gfx_ctx.renderer, gfx.DEFAULT_LIGHT_DIRECTION)
	crosshair_destroy(gfx_ctx, &state.crosshair)
	flare_destroy(gfx_ctx, &state.flare)
	// Jobs write into chunk meshes and indices: drain every bake before any free.
	forest_wait_builds(state, &ctx.jobs)
	for &chunk in state.chunks {
		delete(chunk.static_job.indices)
		delete(chunk.static_data.verts)
		delete(chunk.static_data.idx)
		for lod in 0 ..< 2 {
			delete(chunk.grass_job[lod].indices)
			delete(chunk.grass_data[lod].verts)
			delete(chunk.grass_data[lod].idx)
		}
	}
	physics_destroy(&state.physics, gfx_ctx)
	gfx.material_destroy(&state.material)
	free(state)
}
