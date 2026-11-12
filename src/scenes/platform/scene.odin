// Platformer prototype: boxes, ramps and trapezoids built as extruded convex
// polygons, textured with the Kenney prototype set in static/prototype_textures.
package platform

import "core:math"
import "core:math/linalg"
import gfx "../../engine/gfx"
import default "../../engine/default"
import engine "../../engine"

// Waypoints (centre of the player cube) on platform tops, spread across x, y and z.
PLAYER_PATH := [?][3]f32{{-9, 1.5, 0}, {-6, 1.0, 1}, {-3, 2.8, -3}, {1, 3.8, 3}, {4.5, 5.8, -6}, {9, 7.3, 2}, {4, 1.5, -5}, {0, 0.5, -2}}
PROTO_TILE :: 2.0 // world units per texture repeat

Proto_Material :: enum {
	Ground,
	Platform,
	Ramp,
	Trapezoid,
	Goal,
	Player,
}

PROTO_TEXTURES := [Proto_Material]string {
	.Ground    = "static/prototype_textures/Green/texture_01.png",
	.Platform  = "static/prototype_textures/Orange/texture_01.png",
	.Ramp      = "static/prototype_textures/Light/texture_01.png",
	.Trapezoid = "static/prototype_textures/Purple/texture_01.png",
	.Goal      = "static/prototype_textures/Red/texture_01.png",
	.Player    = "static/prototype_textures/Dark/texture_01.png",
}

Platform_State :: struct {
	pipeline:  gfx.Pipeline_Handle,
	sampler:   gfx.Sampler_Handle,
	textures:  [Proto_Material]gfx.Texture_Handle,
	materials: [Proto_Material]gfx.Material,
	// CPU vertex data must outlive mesh upload; kept until destroy.
	solids:    [dynamic]Proto_Solid,
	meshes:    [dynamic]^gfx.Mesh,
	scene:     gfx.Scene,
	skybox:    default.Skybox,
	fly_camera: default.Fly_Camera,
	player:    int,
	time:      f32,
}

Proto_Solid :: struct {
	verts: [dynamic]gfx.VertexData,
	idx:   [dynamic]u16,
}

platform_scene :: proc() -> engine.Scene {
	return {name = "Platform", create = platform_create, tick = platform_tick, destroy = platform_destroy}
}

platform_create :: proc(demo: ^engine.Scene, dev: ^gfx.Device) -> bool {
	state := new(Platform_State)
	demo.state = state
	engine.scene_camera_reset(demo, dev, {24, 18, 34}, {2, 2, -1})

	state.fly_camera = default.fly_camera_create(dev, "platform")
	state.pipeline = default.create_textured_pipeline(dev)
	state.sampler = gfx.sampler_create(dev, gfx.SAMPLER_TRILINEAR)
	for path, mat in PROTO_TEXTURES {
		state.textures[mat] = gfx.texture_load(dev, path)
		state.materials[mat] = gfx.material_create(state.pipeline)
		default.bind_textured_material(&state.materials[mat], state.textures[mat], state.sampler)
	}

	state.skybox = default.skybox_create(dev, default.SKYBOX_PATH)
	default.skybox_add_to_scene(&state.scene, &state.skybox)

	// Ground covers the whole field (x -24..24, z -14..14) with a pit at x -4..0, z -2..2.
	proto_box(state, dev, {-14, -1, 0}, {10, 1, 14}, .Ground)
	proto_box(state, dev, {12, -1, 0}, {12, 1, 14}, .Ground)
	proto_box(state, dev, {-2, -1, 8}, {2, 1, 6}, .Ground)
	proto_box(state, dev, {-2, -1, -8}, {2, 1, 6}, .Ground)

	// Ramp turned on Y so it climbs diagonally across the ground.
	ramp := proto_piece(state, dev, {{-6, 0}, {0, 0}, {0, 4}}, 4, {-8, 0, 0}, .Ramp)
	gfx.entity_set_rotation_euler(gfx.scene_entity(&state.scene, ramp), 0, 0.6, 0)

	// Trapezoid step set back in depth.
	proto_piece(state, dev, {{-1.5, 0}, {1.5, 0}, {0.8, 3}, {-0.8, 3}}, 2, {4, 0, -5}, .Trapezoid)

	// Floating platforms at different depths, plus an overhang.
	proto_box(state, dev, {-3, 2, -3}, {1.5, 0.3, 1.5}, .Platform)
	proto_box(state, dev, {1, 3.5, 3}, {1.5, 0.3, 1.5}, .Platform)
	proto_box(state, dev, {4.5, 5, -6}, {1.5, 0.3, 1.5}, .Platform)
	proto_piece(state, dev, {{-2, 0.8}, {2, 0.8}, {1.2, -0.8}, {-1.2, -0.8}}, 2, {9, 6, 2}, .Trapezoid)

	// Stairs zig-zagging in depth up to the goal.
	for k in 0 ..< 3 {
		h := f32(k + 1)
		proto_box(state, dev, {9 + 1.5 * f32(k), h / 2, 2 * f32(k % 2) - 1}, {0.75, h / 2, 2}, .Ground)
	}
	proto_box(state, dev, {13.8, 2, -3}, {0.4, 2, 1}, .Goal)

	state.player = proto_box(state, dev, PLAYER_PATH[0], {0.5, 0.5, 0.5}, .Player)
	return true
}

platform_tick :: proc(demo: ^engine.Scene, dev: ^gfx.Device, delta_time: f32) {
	state := cast(^Platform_State)demo.state
	default.fly_camera_tick(&state.fly_camera, dev, delta_time)

	// Player walks a looping 3D path through the platforms, hopping between waypoints.
	state.time += delta_time
	n := len(PLAYER_PATH)
	t := state.time * 0.35
	t -= f32(n) * math.floor(t / f32(n))
	i := int(t)
	f := t - f32(i)
	f = f * f * (3 - 2 * f)
	pos := PLAYER_PATH[i] + (PLAYER_PATH[(i + 1) % n] - PLAYER_PATH[i]) * f
	pos.y += 1.0 * math.sin(f * math.PI)
	gfx.entity_set_position(gfx.scene_entity(&state.scene, state.player), pos)

	gfx.gfx_render(dev, &state.scene)
}

platform_destroy :: proc(demo: ^engine.Scene, dev: ^gfx.Device) {
	state := cast(^Platform_State)demo.state
	gfx.scene_destroy(&state.scene)
	default.skybox_destroy(dev, &state.skybox)
	for mesh in state.meshes {
		gfx.mesh_destroy(dev, mesh)
		free(mesh)
	}
	for &solid in state.solids {
		delete(solid.verts)
		delete(solid.idx)
	}
	delete(state.solids)
	delete(state.meshes)
	for &material in state.materials do gfx.material_destroy(&material)
	for texture in state.textures do gfx.texture_destroy(dev, texture)
	gfx.sampler_destroy(dev, state.sampler)
	gfx.pipeline_destroy(dev, state.pipeline)
	free(state)
}

// Axis-aligned box centred at `center` with half extents `half`.
proto_box :: proc(
	state: ^Platform_State,
	dev: ^gfx.Device,
	center, half: [3]f32,
	material: Proto_Material,
) -> int {
	poly := [4][2]f32{{-half.x, -half.y}, {half.x, -half.y}, {half.x, half.y}, {-half.x, half.y}}
	return proto_piece(state, dev, poly[:], half.z * 2, center, material)
}

// Convex XY polygon (local to `at`, centred on z = 0) extruded by `depth`.
proto_piece :: proc(
	state: ^Platform_State,
	dev: ^gfx.Device,
	poly: [][2]f32,
	depth: f32,
	at: [3]f32,
	material: Proto_Material,
) -> int {
	solid: Proto_Solid
	proto_prism(&solid, poly, depth)
	append(&state.solids, solid)
	stored := &state.solids[len(state.solids) - 1]

	mesh := new(gfx.Mesh)
	mesh^ = gfx.mesh_create(dev, stored.verts[:], stored.idx[:])
	gfx.mesh_upload(&dev.renderer, mesh)
	append(&state.meshes, mesh)

	index := gfx.scene_add_entity(&state.scene)
	entity := gfx.scene_entity(&state.scene, index)
	gfx.entity_set_position(entity, at)
	gfx.entity_add_renderable(entity, mesh, &state.materials[material])
	return index
}

// Extrudes a convex polygon along Z: two caps and one quad per edge.
proto_prism :: proc(solid: ^Proto_Solid, poly: [][2]f32, depth: f32) {
	n := len(poly)
	assert(n >= 3 && n <= 16)
	hz := depth / 2

	centroid: [2]f32
	for p in poly do centroid += p
	centroid /= f32(n)

	front, back: [16][3]f32
	for p, i in poly {
		front[i] = {p.x, p.y, hz}
		back[i] = {p.x, p.y, -hz}
	}
	proto_add_face(solid, {0, 0, 1}, front[:n])
	proto_add_face(solid, {0, 0, -1}, back[:n])

	for i in 0 ..< n {
		a := poly[i]
		b := poly[(i + 1) % n]
		edge := b - a
		outward := linalg.normalize([2]f32{edge.y, -edge.x})
		if linalg.dot(outward, (a + b) / 2 - centroid) < 0 do outward = -outward
		quad := [4][3]f32{{a.x, a.y, hz}, {b.x, b.y, hz}, {b.x, b.y, -hz}, {a.x, a.y, -hz}}
		proto_add_face(solid, {outward.x, outward.y, 0}, quad[:])
	}
}

// Adds a convex planar face as a triangle fan. Winding is chosen so the
// front side faces `normal`, and UVs are planar in world units / PROTO_TILE.
proto_add_face :: proc(solid: ^Proto_Solid, normal: [3]f32, pts: [][3]f32) {
	u := linalg.normalize(pts[1] - pts[0])
	v := linalg.normalize(linalg.cross(u, normal))
	base := u32(len(solid.verts))
	for p in pts {
		d := p - pts[0]
		append(
			&solid.verts,
			gfx.VertexData {
				position = p,
				color = {1, 1, 1, 1},
				normal = normal,
				uv = {linalg.dot(d, u) / PROTO_TILE, linalg.dot(d, v) / PROTO_TILE},
			},
		)
	}
	for i in 1 ..< len(pts) - 1 {
		b := base + u32(i)
		c := base + u32(i + 1)
		if linalg.dot(linalg.cross(pts[i] - pts[0], pts[i + 1] - pts[0]), normal) < 0 do b, c = c, b
		append(&solid.idx, u16(base), u16(b), u16(c))
	}
}
