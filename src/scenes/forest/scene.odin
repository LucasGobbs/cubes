// Forest: stylised BotW-like meadow. The world is 16x16 chunks; each chunk is
// baked once into world-space meshes (terrain+trees, grass at two LODs) and
// streamed in as the camera approaches. Wind and toon shading run entirely in
// shaders/forest.slang, so a frame costs one draw per visible chunk mesh.
package forest

import "core:math"
import default "../../engine/default"
import engine "../../engine"
import gfx "../../engine/gfx"
import shader_parameters "../../shader_parameters"

FOG_DISTANCE :: 420.0 // also the renderer's view distance: farther chunks are culled
BUILD_RADIUS :: FOG_DISTANCE + 12.0
GRASS_NEAR :: 42.0 // dense grass inside; hysteresis keeps LOD from flickering
GRASS_FAR :: 52.0
GRASS_MAX :: 95.0 // no grass past this; the terrain colour carries the meadow
BUILD_PER_FRAME :: 4 // chunk meshes baked per tick once streaming
START_RADIUS :: 140.0 // baked before the first frame; the rest streams in under fog
FOG_COLOR :: [3]f32{0.62, 0.78, 0.95}
SUN_DIRECTION :: [3]f32{0.45, 0.8, 0.35} // shader normalises it; read from time.yzw

Mesh_Data :: struct {
	verts: [dynamic]gfx.VertexData,
	idx:   [dynamic]u16,
}

// Mesh keeps slices into Mesh_Data, so both live until destroy.
Chunk :: struct {
	static_built: bool,
	static_data:  Mesh_Data,
	static_mesh:  gfx.Mesh,
	grass_draw:   int, // -1 until the first grass mesh exists
	grass_lod:    int,
	grass_built:  [2]bool,
	grass_data:   [2]Mesh_Data,
	grass_mesh:   [2]gfx.Mesh,
}

Forest_State :: struct {
	pipeline: gfx.Pipeline_Handle,
	material: gfx.Material,
	bloom:    gfx.Bloom,
	chunks:   [CHUNKS_PER_SIDE * CHUNKS_PER_SIDE]Chunk,
	time:     f32,
}

forest_scene :: proc() -> engine.Scene {
	return {name = "Forest", create = forest_create, tick = forest_tick, destroy = forest_destroy}
}

forest_create :: proc(demo: ^engine.Scene, ctx: ^engine.Context) -> bool {
	gfx_ctx := &ctx.gfx
	state := new(Forest_State)
	demo.state = state
	for &chunk in state.chunks do chunk.grass_draw = -1
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
	// The shader samples the shadow map even with shadows off (shadow_params.x = 0).
	gfx.material_bind_texture(&state.material, shader_parameters.FOREST_FRAGMENT_SHADOW_MAP, shader_parameters.FOREST_FRAGMENT_SHADOW_SAMPLER, gfx_ctx.renderer.shadow_map, gfx_ctx.renderer.shadow_sampler)

	gfx.skybox_add(gfx_ctx, default.SKYBOX_PATH)

	state.bloom = gfx.bloom_create(gfx_ctx, 0.95, 0.2, 5)
	gfx.renderer_set_passes(&gfx_ctx.renderer, .Post, []gfx.Render_Pass{gfx.bloom_pass(&state.bloom)})

	forest_stream(state, gfx_ctx, 1 << 20, START_RADIUS)
	return true
}

// Passes the time wind runs on and the sun the shader lights by; the shader gets
// the draw model matrix so meshes can be stored relative to their chunk origin
// (tight culling bounds).
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
			time = {state.time, SUN_DIRECTION.x, SUN_DIRECTION.y, SUN_DIRECTION.z},
			fog = parameters.fog,
		},
	}
	gfx.draw_push_uniform(draw_context, shader_parameters.FOREST_VERTEX_UNIFORM_BLOCK, &uniforms)
}

forest_tick :: proc(demo: ^engine.Scene, ctx: ^engine.Context, delta_time: f32) {
	gfx_ctx := &ctx.gfx
	state := cast(^Forest_State)demo.state
	state.time += delta_time
	gfx_ctx.renderer.fog = {FOG_COLOR.r, FOG_COLOR.g, FOG_COLOR.b, FOG_DISTANCE}
	forest_stream(state, gfx_ctx, BUILD_PER_FRAME, BUILD_RADIUS)
	gfx.render(gfx_ctx)
}

// Bakes missing meshes for chunks near the camera (nearest-first is not
// needed: the initial pass fills the whole radius) and picks each grass LOD.
// shortcut: built chunks are never freed, so flying the whole world holds
// ~400 MB of vertices; add eviction (with a GPU idle wait) if that matters.
forest_stream :: proc(state: ^Forest_State, gfx_ctx: ^gfx.Device, budget: int, radius: f32) {
	budget := budget
	camera := gfx.camera(gfx_ctx).position
	for index in 0 ..< len(state.chunks) {
		cx, cz := index % CHUNKS_PER_SIDE, index / CHUNKS_PER_SIDE
		ox, oz := chunk_origin(cx, cz)
		dx, dz := ox + CHUNK_SIZE / 2 - camera.x, oz + CHUNK_SIZE / 2 - camera.z
		distance := math.sqrt(dx * dx + dz * dz)
		if distance > radius do continue
		chunk := &state.chunks[index]

		if !chunk.static_built {
			if budget <= 0 do continue
			budget -= 1
			forest_build_static(state, gfx_ctx, chunk, cx, cz)
		}

		if chunk.grass_draw >= 0 {
			// Out of range: hide the draw so it costs no fragments.
			gfx_ctx.draws[chunk.grass_draw].hidden = distance > GRASS_MAX
		}
		if distance > GRASS_MAX do continue

		lod := chunk.grass_lod
		if chunk.grass_draw < 0 do lod = 1
		if distance < GRASS_NEAR do lod = 0
		if distance > GRASS_FAR do lod = 1
		if chunk.grass_draw >= 0 && lod == chunk.grass_lod do continue
		if !chunk.grass_built[lod] {
			if budget <= 0 do continue
			budget -= 1
			forest_build_grass(state, gfx_ctx, chunk, cx, cz, lod)
		}
		chunk.grass_lod = lod
		if chunk.grass_draw < 0 {
			chunk.grass_draw = gfx.draw_create(gfx_ctx, {mesh = &chunk.grass_mesh[lod], material = &state.material, position = {ox, 0, oz}})
		} else {
			gfx_ctx.draws[chunk.grass_draw].mesh = &chunk.grass_mesh[lod]
		}
	}
}

forest_build_static :: proc(state: ^Forest_State, gfx_ctx: ^gfx.Device, chunk: ^Chunk, cx, cz: int) {
	indices := make([dynamic]u32, context.temp_allocator)
	terrain_chunk(cx, cz, &chunk.static_data.verts, &indices)
	trees_chunk(cx, cz, &chunk.static_data.verts, &indices)
	ox, oz := chunk_origin(cx, cz)
	chunk.static_mesh = forest_upload(gfx_ctx, &chunk.static_data, indices[:], ox, oz)
	chunk.static_built = true

	gfx.draw_create(gfx_ctx, {mesh = &chunk.static_mesh, material = &state.material, position = {ox, 0, oz}})
}

forest_build_grass :: proc(state: ^Forest_State, gfx_ctx: ^gfx.Device, chunk: ^Chunk, cx, cz, lod: int) {
	indices := make([dynamic]u32, context.temp_allocator)
	grass_chunk(cx, cz, lod, &chunk.grass_data[lod].verts, &indices)
	ox, oz := chunk_origin(cx, cz)
	chunk.grass_mesh[lod] = forest_upload(gfx_ctx, &chunk.grass_data[lod], indices[:], ox, oz)
	chunk.grass_built[lod] = true
}

// Moves world-space vertices to chunk-local x/z (so the mesh bound is centred
// near the draw), narrows indices to u16, and uploads.
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
	return gfx.mesh_create(gfx_ctx, data.verts[:], data.idx[:])
}

forest_destroy :: proc(demo: ^engine.Scene, ctx: ^engine.Context) {
	gfx_ctx := &ctx.gfx
	state := cast(^Forest_State)demo.state
	gfx.renderer_clear_passes(&gfx_ctx.renderer, .Post)
	for &chunk in state.chunks {
		if chunk.static_built do gfx.mesh_destroy(gfx_ctx, &chunk.static_mesh)
		delete(chunk.static_data.verts)
		delete(chunk.static_data.idx)
		for lod in 0 ..< 2 {
			if chunk.grass_built[lod] do gfx.mesh_destroy(gfx_ctx, &chunk.grass_mesh[lod])
			delete(chunk.grass_data[lod].verts)
			delete(chunk.grass_data[lod].idx)
		}
	}
	gfx.material_destroy(&state.material)
	gfx.pipeline_destroy(gfx_ctx, state.pipeline)
	free(state)
}
