// Forest: stylised BotW-like meadow. The world is 16x16 chunks; each chunk is
// baked once into world-space meshes (terrain+trees, grass at two LODs) and
// streamed in as the camera approaches. Wind and toon shading run entirely in
// shaders/forest.slang, so a frame costs one draw per visible chunk mesh.
package forest_naive

import "core:math"
import gfx "../../engine/gfx"
import default "../../engine/default"
import shader_parameters "../../shader_parameters"
import engine "../../engine"

SUN_DIRECTION :: [3]f32{0.30, 0.38, -0.87} // unit; in front of the spawn view so the flare is seen at start
FOG_DISTANCE :: 560.0 // also the renderer's view distance: farther chunks are culled
BUILD_RADIUS :: FOG_DISTANCE + 12.0
GRASS_NEAR :: 42.0 // dense grass inside; hysteresis keeps LOD from flickering
GRASS_FAR :: 52.0
GRASS_MAX :: 95.0 // no grass past this; the terrain colour carries the meadow
BUILD_PER_FRAME :: 6 // chunk meshes baked per tick once streaming
START_RADIUS :: 140.0 // baked before the first frame; the rest streams in under fog
FOG_COLOR :: [3]f32{0.62, 0.78, 0.95}

Mesh_Data :: struct {
	verts: [dynamic]gfx.VertexData,
	idx:   [dynamic]u16,
}

// Mesh keeps slices into Mesh_Data, so both live until destroy.
Chunk :: struct {
	static_built:  bool,
	static_data:   Mesh_Data,
	static_mesh:   gfx.Mesh,
	grass_entity:  int, // -1 until the first grass mesh exists
	grass_lod:     int,
	grass_built:   [2]bool,
	grass_data:    [2]Mesh_Data,
	grass_mesh:    [2]gfx.Mesh,
}

Forest_State :: struct {
	pipeline:   gfx.Pipeline_Handle,
	material:   gfx.Material,
	scene:      gfx.Scene,
	skybox:     default.Skybox,
	bloom:      default.Bloom,
	fly_camera: default.Fly_Camera,
	chunks:     [CHUNKS_PER_SIDE * CHUNKS_PER_SIDE]Chunk,
	time:       f32,
	flare:      Flare,
}

forest_naive_scene :: proc() -> engine.Scene {
	return {name = "Forest (naive)", create = forest_create, tick = forest_tick, destroy = forest_destroy}
}

forest_create :: proc(demo: ^engine.Scene, dev: ^gfx.Device) -> bool {
	state := new(Forest_State)
	demo.state = state
	for &chunk in state.chunks do chunk.grass_entity = -1
	engine.scene_camera_reset(demo, dev, {0, terrain_height(0, 0) + 2.5, 0}, {0, terrain_height(0, -10) + 2, -10})
	state.fly_camera = default.fly_camera_create(dev, "forest")

	attributes := shader_parameters.forest_vertex_attributes(gfx.VertexData)
	state.pipeline = gfx.gfx_pipeline_create(
		dev,
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
	state.material = gfx.material_create(state.pipeline)

	state.skybox = default.skybox_create(dev, default.SKYBOX_PATH)
	default.skybox_add_to_scene(&state.scene, &state.skybox)

	state.bloom = default.bloom_create(dev, 0.95, 0.2, 5)
	gfx.renderer_set_passes(&dev.renderer, .Post, []gfx.Render_Pass{default.bloom_pass(&state.bloom)})
	flare_create(dev, &state.flare)

	forest_stream(state, dev, 1 << 20, START_RADIUS)
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
		},
	}
	gfx.draw_push_uniform(draw_context, shader_parameters.FOREST_VERTEX_UNIFORM_BLOCK, &uniforms)
}

forest_tick :: proc(demo: ^engine.Scene, dev: ^gfx.Device, delta_time: f32) {
	state := cast(^Forest_State)demo.state
	default.fly_camera_tick(&state.fly_camera, dev, delta_time)
	state.time += delta_time
	dev.renderer.fog = {FOG_COLOR.r, FOG_COLOR.g, FOG_COLOR.b, FOG_DISTANCE}
	forest_stream(state, dev, BUILD_PER_FRAME, BUILD_RADIUS)
	flare_update(dev, &state.flare, SUN_DIRECTION)
	gfx.gfx_render(dev, &state.scene)
}

// Bakes missing meshes for chunks near the camera (nearest-first is not
// needed: the initial pass fills the whole radius) and picks each grass LOD.
// shortcut: built chunks are never freed, so flying the whole world holds
// ~400 MB of vertices; add eviction (with a GPU idle wait) if that matters.
forest_stream :: proc(state: ^Forest_State, dev: ^gfx.Device, budget: int, radius: f32) {
	budget := budget
	camera := gfx.gfx_camera(dev).position
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
			forest_build_static(state, dev, chunk, cx, cz)
		}

		if chunk.grass_entity >= 0 {
			// Out of range: collapse the entity so it costs no fragments.
			entity := gfx.scene_entity(&state.scene, chunk.grass_entity)
			gfx.entity_set_scale(entity, distance > GRASS_MAX ? {0, 0, 0} : {1, 1, 1})
		}
		if distance > GRASS_MAX do continue

		lod := chunk.grass_lod
		if chunk.grass_entity < 0 do lod = 1
		if distance < GRASS_NEAR do lod = 0
		if distance > GRASS_FAR do lod = 1
		if chunk.grass_entity >= 0 && lod == chunk.grass_lod do continue
		if !chunk.grass_built[lod] {
			if budget <= 0 do continue
			budget -= 1
			forest_build_grass(state, dev, chunk, cx, cz, lod)
		}
		chunk.grass_lod = lod
		if chunk.grass_entity < 0 {
			chunk.grass_entity = gfx.scene_add_entity(&state.scene)
			entity := gfx.scene_entity(&state.scene, chunk.grass_entity)
			gfx.entity_set_position(entity, {ox, 0, oz})
			gfx.entity_add_renderable(entity, &chunk.grass_mesh[lod], &state.material)
		} else {
			gfx.entity_renderable(gfx.scene_entity(&state.scene, chunk.grass_entity)).mesh = &chunk.grass_mesh[lod]
		}
	}
}

forest_build_static :: proc(state: ^Forest_State, dev: ^gfx.Device, chunk: ^Chunk, cx, cz: int) {
	indices := make([dynamic]u32, context.temp_allocator)
	terrain_chunk(cx, cz, &chunk.static_data.verts, &indices)
	trees_chunk(cx, cz, &chunk.static_data.verts, &indices)
	ox, oz := chunk_origin(cx, cz)
	chunk.static_mesh = forest_upload(dev, &chunk.static_data, indices[:], ox, oz)
	chunk.static_built = true

	entity := gfx.scene_entity(&state.scene, gfx.scene_add_entity(&state.scene))
	gfx.entity_set_position(entity, {ox, 0, oz})
	gfx.entity_add_renderable(entity, &chunk.static_mesh, &state.material)
}

forest_build_grass :: proc(state: ^Forest_State, dev: ^gfx.Device, chunk: ^Chunk, cx, cz, lod: int) {
	indices := make([dynamic]u32, context.temp_allocator)
	grass_chunk(cx, cz, lod, &chunk.grass_data[lod].verts, &indices)
	ox, oz := chunk_origin(cx, cz)
	chunk.grass_mesh[lod] = forest_upload(dev, &chunk.grass_data[lod], indices[:], ox, oz)
	chunk.grass_built[lod] = true
}

// Moves world-space vertices to chunk-local x/z (so the mesh bound is centred
// near the entity), narrows indices to u16, and uploads.
forest_upload :: proc(dev: ^gfx.Device, data: ^Mesh_Data, indices: []u32, ox, oz: f32) -> gfx.Mesh {
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
	mesh := gfx.mesh_create(dev, data.verts[:], data.idx[:])
	gfx.mesh_upload(&dev.renderer, &mesh)
	return mesh
}

forest_destroy :: proc(demo: ^engine.Scene, dev: ^gfx.Device) {
	state := cast(^Forest_State)demo.state
	gfx.renderer_clear_passes(&dev.renderer, .Post)
	flare_destroy(dev, &state.flare)
	gfx.scene_destroy(&state.scene)
	default.skybox_destroy(dev, &state.skybox)
	for &chunk in state.chunks {
		if chunk.static_built do gfx.mesh_destroy(dev, &chunk.static_mesh)
		delete(chunk.static_data.verts)
		delete(chunk.static_data.idx)
		for lod in 0 ..< 2 {
			if chunk.grass_built[lod] do gfx.mesh_destroy(dev, &chunk.grass_mesh[lod])
			delete(chunk.grass_data[lod].verts)
			delete(chunk.grass_data[lod].idx)
		}
	}
	gfx.material_destroy(&state.material)
	gfx.gfx_pipeline_destroy(dev, state.pipeline)
	free(state)
}
