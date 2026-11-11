// Forest: stylised BotW-like meadow. The world is 16x16 chunks; each chunk is
// baked once into world-space meshes (terrain+trees, grass at two LODs) and
// streamed in as the camera approaches. Wind and toon shading run entirely in
// shaders/forest.slang, so a frame costs one draw per visible chunk mesh.
package forest

import "core:math"
import gbbfx "../../gbbfx"
import defaults "../../gbbfx/defaults"
import scenekit "../../scenekit"
import shader_parameters "../../shader_parameters"

FOG_DISTANCE :: 110.0 // also the renderer's view distance: farther chunks are culled
BUILD_RADIUS :: FOG_DISTANCE + 12.0
GRASS_NEAR :: 40.0 // dense grass inside; hysteresis keeps LOD from flickering
GRASS_FAR :: 48.0
BUILD_PER_FRAME :: 2 // chunk meshes baked per tick once streaming
FOG_COLOR :: [3]f32{0.55, 0.72, 0.92}

Mesh_Data :: struct {
	verts: [dynamic]gbbfx.VertexData,
	idx:   [dynamic]u16,
}

// Mesh keeps slices into Mesh_Data, so both live until destroy.
Chunk :: struct {
	static_built:  bool,
	static_data:   Mesh_Data,
	static_mesh:   gbbfx.Mesh,
	grass_entity:  int, // -1 until the first grass mesh exists
	grass_lod:     int,
	grass_built:   [2]bool,
	grass_data:    [2]Mesh_Data,
	grass_mesh:    [2]gbbfx.Mesh,
}

Forest_State :: struct {
	pipeline:   gbbfx.Pipeline_Handle,
	material:   gbbfx.Material,
	scene:      gbbfx.Scene,
	skybox:     defaults.Skybox,
	bloom:      defaults.Bloom,
	fly_camera: scenekit.FlyCamera,
	chunks:     [CHUNKS_PER_SIDE * CHUNKS_PER_SIDE]Chunk,
	time:       f32,
}

forest_scene :: proc() -> scenekit.Scene {
	return {name = "Forest", create = forest_create, tick = forest_tick, destroy = forest_destroy}
}

forest_create :: proc(demo: ^scenekit.Scene, gfx: ^gbbfx.Gfx) -> bool {
	state := new(Forest_State)
	demo.state = state
	for &chunk in state.chunks do chunk.grass_entity = -1
	scenekit.camera_reset(gfx, {0, terrain_height(0, 0) + 2.5, 0}, {0, terrain_height(0, -10) + 2, -10})
	state.fly_camera = scenekit.fly_camera_create(gfx, "forest")

	attributes := shader_parameters.forest_vertex_attributes(gbbfx.VertexData)
	state.pipeline = gbbfx.gfx_pipeline_create(
		gfx,
		{
			vertex = shader_parameters.forest_vertex(),
			fragment = shader_parameters.forest_fragment(),
			vertex_attributes = attributes[:],
			vertex_stride = u32(size_of(gbbfx.VertexData)),
			depth_test = true,
			depth_write = true,
			cull_mode = .NONE, // grass is two-sided; closed meshes are depth-rejected anyway
			bind_draw = forest_bind_draw,
			user_data = state,
		},
	)
	state.material = gbbfx.material_create(state.pipeline)

	state.skybox = defaults.skybox_create(gfx, scenekit.SKYBOX_PATH)
	defaults.skybox_add_to_scene(&state.scene, &state.skybox)

	state.bloom = defaults.bloom_create(gfx, 0.85, 0.3, 5)
	gbbfx.renderer_set_passes(&gfx.renderer, .Post, []gbbfx.Render_Pass{defaults.bloom_pass(&state.bloom)})

	forest_stream(state, gfx, 1 << 20) // everything in range before the first frame
	return true
}

// Passes the time wind runs on; the shader gets the entity model matrix so
// meshes can be stored relative to their chunk origin (tight culling bounds).
forest_bind_draw :: proc(
	user_data: rawptr,
	draw_context: ^gbbfx.Draw_Context,
	parameters: gbbfx.Draw_Parameters,
) {
	state := cast(^Forest_State)user_data
	camera := parameters.camera_position
	uniforms := shader_parameters.ForestVertexUniformBlock {
		data = {
			view_projection = parameters.view_projection,
			model = parameters.model_transform,
			camera_position = {camera.x, camera.y, camera.z, 1},
			time = {state.time, 0, 0, 0},
			fog = parameters.fog,
		},
	}
	gbbfx.draw_push_uniform(draw_context, shader_parameters.FOREST_VERTEX_UNIFORM_BLOCK, &uniforms)
}

forest_tick :: proc(demo: ^scenekit.Scene, gfx: ^gbbfx.Gfx, delta_time: f32) {
	state := cast(^Forest_State)demo.state
	scenekit.fly_camera_tick(&state.fly_camera, gfx, delta_time)
	state.time += delta_time
	gfx.renderer.fog = {FOG_COLOR.r, FOG_COLOR.g, FOG_COLOR.b, FOG_DISTANCE}
	forest_stream(state, gfx, BUILD_PER_FRAME)
	gbbfx.gfx_render(gfx, &state.scene)
}

// Bakes missing meshes for chunks near the camera (nearest-first is not
// needed: the initial pass fills the whole radius) and picks each grass LOD.
// shortcut: built chunks are never freed, so flying the whole world holds
// ~400 MB of vertices; add eviction (with a GPU idle wait) if that matters.
forest_stream :: proc(state: ^Forest_State, gfx: ^gbbfx.Gfx, budget: int) {
	budget := budget
	camera := gbbfx.gfx_camera(gfx).position
	for index in 0 ..< len(state.chunks) {
		cx, cz := index % CHUNKS_PER_SIDE, index / CHUNKS_PER_SIDE
		ox, oz := chunk_origin(cx, cz)
		dx, dz := ox + CHUNK_SIZE / 2 - camera.x, oz + CHUNK_SIZE / 2 - camera.z
		distance := math.sqrt(dx * dx + dz * dz)
		if distance > BUILD_RADIUS do continue
		chunk := &state.chunks[index]

		if !chunk.static_built {
			if budget <= 0 do continue
			budget -= 1
			forest_build_static(state, gfx, chunk, cx, cz)
		}

		lod := chunk.grass_lod
		if chunk.grass_entity < 0 do lod = 1
		if distance < GRASS_NEAR do lod = 0
		if distance > GRASS_FAR do lod = 1
		if chunk.grass_entity >= 0 && lod == chunk.grass_lod do continue
		if !chunk.grass_built[lod] {
			if budget <= 0 do continue
			budget -= 1
			forest_build_grass(state, gfx, chunk, cx, cz, lod)
		}
		chunk.grass_lod = lod
		if chunk.grass_entity < 0 {
			chunk.grass_entity = gbbfx.scene_add_entity(&state.scene)
			entity := gbbfx.scene_entity(&state.scene, chunk.grass_entity)
			gbbfx.entity_set_position(entity, {ox, 0, oz})
			gbbfx.entity_add_renderable(entity, &chunk.grass_mesh[lod], &state.material)
		} else {
			gbbfx.entity_renderable(gbbfx.scene_entity(&state.scene, chunk.grass_entity)).mesh = &chunk.grass_mesh[lod]
		}
	}
}

forest_build_static :: proc(state: ^Forest_State, gfx: ^gbbfx.Gfx, chunk: ^Chunk, cx, cz: int) {
	indices := make([dynamic]u32, context.temp_allocator)
	terrain_chunk(cx, cz, &chunk.static_data.verts, &indices)
	trees_chunk(cx, cz, &chunk.static_data.verts, &indices)
	ox, oz := chunk_origin(cx, cz)
	chunk.static_mesh = forest_upload(gfx, &chunk.static_data, indices[:], ox, oz)
	chunk.static_built = true

	entity := gbbfx.scene_entity(&state.scene, gbbfx.scene_add_entity(&state.scene))
	gbbfx.entity_set_position(entity, {ox, 0, oz})
	gbbfx.entity_add_renderable(entity, &chunk.static_mesh, &state.material)
}

forest_build_grass :: proc(state: ^Forest_State, gfx: ^gbbfx.Gfx, chunk: ^Chunk, cx, cz, lod: int) {
	indices := make([dynamic]u32, context.temp_allocator)
	grass_chunk(cx, cz, lod, &chunk.grass_data[lod].verts, &indices)
	ox, oz := chunk_origin(cx, cz)
	chunk.grass_mesh[lod] = forest_upload(gfx, &chunk.grass_data[lod], indices[:], ox, oz)
	chunk.grass_built[lod] = true
}

// Moves world-space vertices to chunk-local x/z (so the mesh bound is centred
// near the entity), narrows indices to u16, and uploads.
forest_upload :: proc(gfx: ^gbbfx.Gfx, data: ^Mesh_Data, indices: []u32, ox, oz: f32) -> gbbfx.Mesh {
	assert(len(data.verts) < 1 << 16, "chunk mesh too large for u16 indices")
	for &vertex in data.verts {
		vertex.position.x -= ox
		vertex.position.z -= oz
	}
	resize(&data.idx, len(indices))
	for index, i in indices do data.idx[i] = u16(index)
	mesh := gbbfx.mesh_create(gfx, data.verts[:], data.idx[:])
	gbbfx.mesh_upload(&gfx.renderer, &mesh)
	return mesh
}

forest_destroy :: proc(demo: ^scenekit.Scene, gfx: ^gbbfx.Gfx) {
	state := cast(^Forest_State)demo.state
	gbbfx.renderer_clear_passes(&gfx.renderer, .Post)
	gbbfx.scene_destroy(&state.scene)
	defaults.skybox_destroy(gfx, &state.skybox)
	for &chunk in state.chunks {
		if chunk.static_built do gbbfx.mesh_destroy(gfx, &chunk.static_mesh)
		delete(chunk.static_data.verts)
		delete(chunk.static_data.idx)
		for lod in 0 ..< 2 {
			if chunk.grass_built[lod] do gbbfx.mesh_destroy(gfx, &chunk.grass_mesh[lod])
			delete(chunk.grass_data[lod].verts)
			delete(chunk.grass_data[lod].idx)
		}
	}
	gbbfx.material_destroy(&state.material)
	gbbfx.gfx_pipeline_destroy(gfx, state.pipeline)
	free(state)
}
