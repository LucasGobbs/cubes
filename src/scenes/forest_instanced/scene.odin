// Forest (instanced): same world, terrain, grass and look as forest_naive, but
// trees, rocks and bushes are not baked into the ground meshes. A fixed set of
// variant meshes (trees.odin) is uploaded once, and every placed tree is a
// draw pointing at one of them; the renderer collapses identical
// (mesh, material) items into one instanced draw per variant, with transforms
// from its instance storage buffer (shaders/forest_instanced.slang).
// Ground is merged into clusters (terrain 64 m, grass 32 m) so the frame costs
// tens of draws instead of one or two per 16 m chunk; clusters use u32 indices.
package forest_instanced

import "core:math"
import "core:math/linalg"
import gfx "../../engine/gfx"
import default "../../engine/default"
import input "../../engine/input"
import naive "../forest_naive"
import shader_parameters "../../shader_parameters"
import engine "../../engine"
import "core:log"
import phys "../../engine/physics"

CHUNK_SIZE :: naive.CHUNK_SIZE
TERRAIN_SPAN :: 4 // chunks per terrain cluster side (64 m)
GRASS_SPAN :: 2 // chunks per grass cluster side (32 m)
TERRAIN_SIDE :: naive.CHUNKS_PER_SIDE / TERRAIN_SPAN
GRASS_SIDE :: naive.CHUNKS_PER_SIDE / GRASS_SPAN

FOG_DISTANCE :: naive.FOG_DISTANCE
BUILD_RADIUS :: FOG_DISTANCE + 12.0
GRASS_NEAR :: naive.GRASS_NEAR
GRASS_FAR :: naive.GRASS_FAR
GRASS_MAX :: naive.GRASS_MAX
START_RADIUS :: naive.START_RADIUS
BUILD_BUDGET :: 6 // per tick; a terrain cluster costs TERRAIN_COST, a grass cluster 1
TERRAIN_COST :: 3

// Mesh keeps slices into Mesh_Data, so both live until destroy.
Mesh_Data :: struct {
	verts: [dynamic]gfx.VertexData,
	idx:   [dynamic]u32,
}

Terrain_Cluster :: struct {
	built: bool,
	data:  Mesh_Data,
	mesh:  gfx.Mesh,
}

Grass_Item :: struct {
	draw:     int,
	instance: Grass_Instance,
}

Grass_Cluster :: struct {
	built: bool,
	state: int, // 0 hidden, 1 near LOD, 2 far LOD
	items: [dynamic]Grass_Item,
}

Forest_State :: struct {
	pipeline:         gfx.Pipeline_Handle,
	material:         gfx.Material,
	bloom:            gfx.Bloom,
	variant_data:     [naive.VARIANT_COUNT]Variant_Data,
	variant_mesh:     [naive.VARIANT_COUNT]gfx.Mesh,
	terrain:          [TERRAIN_SIDE * TERRAIN_SIDE]Terrain_Cluster,
	grass:            [GRASS_SIDE * GRASS_SIDE]Grass_Cluster,
	tuft_data:        [TUFT_COUNT]Variant_Data,
	tuft_mesh:        [TUFT_COUNT]gfx.Mesh,
	grass_scratch:    [dynamic]Grass_Instance,
	placements:       [dynamic]naive.Instance, // scratch, reused per chunk
	time:             f32,
	flare:            naive.Flare,
	crosshair:        naive.Crosshair, // C: toggles the screen-centre cross
	shadow_action:    input.Button_Action, // H: toggles renderer.shadow_enabled
	physics:          naive.Physics,
	ball_action:      input.Button_Action, // B: launches the ball from the camera
}

forest_instanced_scene :: proc() -> engine.Scene {
	return {name = "Forest (instanced)", create = forest_create, tick = forest_tick, fixed_tick = forest_fixed_tick, destroy = forest_destroy}
}

forest_create :: proc(demo: ^engine.Scene, ctx: ^engine.Context) -> bool {
	gfx_ctx := &ctx.gfx
	state := new(Forest_State)
	demo.state = state
	engine.camera_fly(ctx, {0, naive.terrain_height(0, 0) + 2.5, 0}, {0, naive.terrain_height(0, -10) + 2, -10})

	attributes := shader_parameters.forest_instanced_vertex_attributes(gfx.VertexData)
	state.pipeline = gfx.pipeline_create(
		gfx_ctx,
		{
			vertex = shader_parameters.forest_instanced_vertex(),
			fragment = shader_parameters.forest_instanced_fragment(),
			vertex_attributes = attributes[:],
			vertex_stride = u32(size_of(gfx.VertexData)),
			depth_test = true,
			depth_write = true,
			cull_mode = .NONE, // grass is two-sided
			instanced = true,
			bind_draw = forest_bind_draw,
			user_data = state,
		},
	)
	state.material = gfx.material_make(state.pipeline)
	gfx.material_bind_texture(&state.material, shader_parameters.FOREST_INSTANCED_FRAGMENT_SHADOW_MAP, shader_parameters.FOREST_INSTANCED_FRAGMENT_SHADOW_SAMPLER, gfx_ctx.renderer.shadow_map, gfx_ctx.renderer.shadow_sampler)
	gfx_ctx.renderer.light_direction = naive.SUN_DIRECTION
	state.shadow_action = input.button(&ctx.input, "forest_instanced.shadows", .H, "Toggle shadows")

	state.variant_data = variants_build()
	for &data, index in state.variant_data {
		state.variant_mesh[index] = gfx.mesh_create(gfx_ctx, data.verts[:], data.idx[:])
	}
	state.tuft_data = tufts_build()
	for &data, index in state.tuft_data {
		state.tuft_mesh[index] = gfx.mesh_create(gfx_ctx, data.verts[:], data.idx[:])
	}

	gfx.skybox_add(gfx_ctx, default.SKYBOX_PATH)

	state.bloom = gfx.bloom_create(gfx_ctx, 0.95, 0.2, 5)
	gfx.renderer_set_passes(&gfx_ctx.renderer, .Post, []gfx.Render_Pass{gfx.bloom_pass(&state.bloom)})
	naive.flare_create(gfx_ctx, &state.flare)
	naive.crosshair_create(gfx_ctx, &state.crosshair, input.button(&ctx.input, "forest_instanced.crosshair", .C, "Toggle crosshair")) // after flare: flare resets After_Scene

	naive.physics_create(&state.physics, gfx_ctx, &state.material, .Placements)
	state.ball_action = input.button(&ctx.input, "forest_instanced.ball", .B, "Launch ball")
	forest_stream(state, gfx_ctx, 1 << 20, START_RADIUS)
	return true
}

forest_bind_draw :: proc(
	user_data: rawptr,
	draw_context: ^gfx.Draw_Context,
	parameters: gfx.Draw_Parameters,
) {
	state := cast(^Forest_State)user_data
	sun := naive.SUN_DIRECTION
	uniforms := shader_parameters.ForestInstancedVertexUniformBlock {
		data = {
			view_projection = parameters.view_projection,
			camera_position = parameters.camera_position,
			first_instance = parameters.first_instance,
			time = {state.time, sun.x, sun.y, sun.z},
			fog = parameters.fog,
			light_view_projection = parameters.light_view_projection,
			shadow_params = {parameters.shadow_enabled ? f32(1) : f32(0), naive.SHADOW_BIAS, 1.0 / gfx.SHADOW_MAP_SIZE, 0},
		},
	}
	gfx.draw_push_uniform(draw_context, shader_parameters.FOREST_INSTANCED_VERTEX_UNIFORM_BLOCK, &uniforms)
}

forest_tick :: proc(demo: ^engine.Scene, ctx: ^engine.Context, delta_time: f32) {
	gfx_ctx := &ctx.gfx
	state := cast(^Forest_State)demo.state
	state.time += delta_time
	if input.pressed(&ctx.input, state.shadow_action) {
		gfx_ctx.renderer.shadow_enabled = !gfx_ctx.renderer.shadow_enabled
	}
	if input.pressed(&ctx.input, state.ball_action) do naive.physics_launch(&state.physics, gfx_ctx)
	fog := naive.FOG_COLOR
	gfx_ctx.renderer.fog = {fog.r, fog.g, fog.b, FOG_DISTANCE}
	forest_stream(state, gfx_ctx, BUILD_BUDGET, BUILD_RADIUS)
	naive.flare_update(gfx_ctx, &state.flare, naive.SUN_DIRECTION)
	naive.crosshair_update(gfx_ctx, &state.crosshair, &ctx.input)
	naive.physics_draw(&state.physics, gfx_ctx, ctx.blend)
	gfx.render(gfx_ctx)
}

forest_fixed_tick :: proc(demo: ^engine.Scene, ctx: ^engine.Context, delta_time: f32) {
	state := cast(^Forest_State)demo.state
	naive.physics_step(&state.physics, delta_time)
}

// Distance from the camera to a cluster centre; span in chunks, (i, j) cluster index.
cluster_distance :: proc(camera: [3]f32, i, j, span: int) -> (distance, ox, oz: f32) {
	ox, oz = naive.chunk_origin(i * span, j * span)
	size := f32(span) * CHUNK_SIZE
	dx, dz := ox + size / 2 - camera.x, oz + size / 2 - camera.z
	return math.sqrt(dx * dx + dz * dz), ox, oz
}

// Builds missing ground clusters near the camera and picks each grass LOD.
// `budget` counts work units per call (a terrain cluster is TERRAIN_COST).
// shortcut: built clusters are never freed (tree draws included); add
// eviction with a GPU idle wait if memory matters.
forest_stream :: proc(state: ^Forest_State, gfx_ctx: ^gfx.Device, budget: int, radius: f32) {
	budget := budget
	camera := gfx.camera(gfx_ctx).position
	extra := f32(TERRAIN_SPAN) * CHUNK_SIZE * 0.7 // cluster centre -> far corner
	for index in 0 ..< len(state.terrain) {
		i, j := index % TERRAIN_SIDE, index / TERRAIN_SIDE
		distance, ox, oz := cluster_distance(camera, i, j, TERRAIN_SPAN)
		cluster := &state.terrain[index]
		if cluster.built || distance > radius + extra || budget < TERRAIN_COST do continue
		budget -= TERRAIN_COST
		forest_build_terrain(state, gfx_ctx, cluster, i, j, ox, oz)
	}

	extra = f32(GRASS_SPAN) * CHUNK_SIZE * 0.7
	for index in 0 ..< len(state.grass) {
		i, j := index % GRASS_SIDE, index / GRASS_SIDE
		distance, _, _ := cluster_distance(camera, i, j, GRASS_SPAN)
		cluster := &state.grass[index]
		want := cluster.state // hysteresis between the near and far distances
		if distance > GRASS_MAX + extra do want = 0
		else if distance < GRASS_NEAR + extra do want = 1
		else if distance > GRASS_FAR + extra do want = 2
		else if want == 0 do want = 2
		if want == cluster.state do continue
		if !cluster.built {
			if budget <= 0 do continue
			budget -= 1
			forest_build_grass(state, gfx_ctx, cluster, i, j)
		}
		grass_apply_lod(state, gfx_ctx, cluster, want)
	}
}

forest_build_terrain :: proc(state: ^Forest_State, gfx_ctx: ^gfx.Device, cluster: ^Terrain_Cluster, i, j: int, ox, oz: f32) {
	clear(&state.placements)
	for dz in 0 ..< TERRAIN_SPAN {
		for dx in 0 ..< TERRAIN_SPAN {
			cx, cz := i * TERRAIN_SPAN + dx, j * TERRAIN_SPAN + dz
			naive.terrain_chunk(cx, cz, &cluster.data.verts, &cluster.data.idx)
			naive.placements_chunk(cx, cz, &state.placements)
		}
	}
	cluster.mesh = forest_upload(gfx_ctx, &cluster.data, ox, oz)
	cluster.built = true

	gfx.draw_create(gfx_ctx, {mesh = &cluster.mesh, material = &state.material, position = {ox, 0, oz}})

	// One draw per tree/rock/bush, sharing the variant meshes.
	for instance in state.placements {
		rotation := linalg.quaternion_angle_axis_f32(instance.yaw, {0, 1, 0})
		scale := instance.scale
		gfx.draw_create(gfx_ctx, {mesh = &state.variant_mesh[instance.variant], material = &state.material, position = instance.position, rotation = rotation, scale = {scale, scale, scale}})
	}
}

// One draw per grass clump/flower, sharing the tuft meshes. Created hidden;
// grass_apply_lod shows them.
forest_build_grass :: proc(state: ^Forest_State, gfx_ctx: ^gfx.Device, cluster: ^Grass_Cluster, i, j: int) {
	clear(&state.grass_scratch)
	for dz in 0 ..< GRASS_SPAN {
		for dx in 0 ..< GRASS_SPAN {
			grass_placements(i * GRASS_SPAN + dx, j * GRASS_SPAN + dz, &state.grass_scratch)
		}
	}
	for instance in state.grass_scratch {
		rotation := linalg.quaternion_angle_axis_f32(instance.yaw, {0, 1, 0})
		scale := instance.scale
		index := gfx.draw_create(gfx_ctx, {mesh = &state.tuft_mesh[instance.lod1], material = &state.material, position = instance.position, rotation = rotation, scale = {scale, scale, scale}})
		gfx_ctx.draws[index].hidden = true
		append(&cluster.items, Grass_Item{index, instance})
	}
	cluster.built = true
}

// want: 0 hidden (skipped on submit), 1 near LOD, 2 far LOD.
grass_apply_lod :: proc(state: ^Forest_State, gfx_ctx: ^gfx.Device, cluster: ^Grass_Cluster, want: int) {
	for item in cluster.items {
		draw := &gfx_ctx.draws[item.draw]
		draw.hidden = want == 0
		if want == 0 do continue
		variant := item.instance.lod0 if want == 1 else item.instance.lod1
		draw.mesh = &state.tuft_mesh[variant]
	}
	cluster.state = want
}

// Moves world-space vertices to cluster-local x/z (so the mesh bound sits near
// the entity) and uploads. SDL rejects 0-byte buffers, so an empty cluster gets
// one degenerate (invisible) triangle.
forest_upload :: proc(gfx_ctx: ^gfx.Device, data: ^Mesh_Data, ox, oz: f32) -> gfx.Mesh {
	if len(data.verts) == 0 {
		resize(&data.verts, 3)
		resize(&data.idx, 3)
	}
	for &vertex in data.verts {
		vertex.position.x -= ox
		vertex.position.z -= oz
	}
	mesh := gfx.mesh_create(gfx_ctx, data.verts[:], data.idx[:])
	return mesh
}

forest_destroy :: proc(demo: ^engine.Scene, ctx: ^engine.Context) {
	gfx_ctx := &ctx.gfx
	state := cast(^Forest_State)demo.state
	gfx.renderer_clear_passes(&gfx_ctx.renderer, .Post)
	gfx.renderer_update_light(&gfx_ctx.renderer, gfx.DEFAULT_LIGHT_DIRECTION)
	naive.crosshair_destroy(gfx_ctx, &state.crosshair)
	naive.flare_destroy(gfx_ctx, &state.flare)
	for &cluster in state.terrain {
		delete(cluster.data.verts)
		delete(cluster.data.idx)
	}
	for &cluster in state.grass do delete(cluster.items)
	for index in 0 ..< naive.VARIANT_COUNT {
		delete(state.variant_data[index].verts)
		delete(state.variant_data[index].idx)
	}
	delete(state.placements)
	delete(state.grass_scratch)
	for index in 0 ..< TUFT_COUNT {
		delete(state.tuft_data[index].verts)
		delete(state.tuft_data[index].idx)
	}
	ball_pos, _ := phys.body_pose(state.physics.balls[0].track.body)
	log.infof("forest ball y=%.3f ground=%.3f", ball_pos.y, naive.terrain_height(ball_pos.x, ball_pos.z))
	naive.physics_destroy(&state.physics, gfx_ctx)
	gfx.material_destroy(&state.material)
	free(state)
}
