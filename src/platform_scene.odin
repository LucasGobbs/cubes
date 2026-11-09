// Platformer prototype: boxes, ramps and trapezoids built as extruded convex
// polygons, textured with the Kenney prototype set in static/prototype_textures.
package main

import "core:math"
import "core:math/linalg"
import gbbfx "gbbfx"
import defaults "gbbfx/defaults"

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
	pipeline:  gbbfx.Pipeline_Handle,
	sampler:   gbbfx.Sampler_Handle,
	textures:  [Proto_Material]gbbfx.Texture_Handle,
	materials: [Proto_Material]gbbfx.Material,
	// CPU vertex data must outlive mesh upload; kept until destroy.
	solids:    [dynamic]Proto_Solid,
	meshes:    [dynamic]^gbbfx.Mesh,
	scene:     gbbfx.Scene,
	skybox:    defaults.Skybox,
	fly_camera: FlyCamera,
	player:    int,
	time:      f32,
}

Proto_Solid :: struct {
	verts: [dynamic]gbbfx.VertexData,
	idx:   [dynamic]u16,
}

platform_scene :: proc() -> Scene {
	return {name = "Platform", create = platform_create, tick = platform_tick, destroy = platform_destroy}
}

platform_create :: proc(demo: ^Scene, gfx: ^gbbfx.Gfx) -> bool {
	state := new(Platform_State)
	demo.state = state
	camera_reset(gfx, {0, 3, 24}, {0, 2.5, 0})

	state.fly_camera = fly_camera_create(gfx, "platform")
	state.pipeline = defaults.create_textured_pipeline(gfx)
	state.sampler = gbbfx.gfx_sampler_create(gfx, gbbfx.SAMPLER_TRILINEAR)
	for path, mat in PROTO_TEXTURES {
		state.textures[mat] = gbbfx.gfx_texture_load(gfx, path)
		state.materials[mat] = gbbfx.material_create(state.pipeline)
		defaults.bind_textured_material(&state.materials[mat], state.textures[mat], state.sampler)
	}

	state.skybox = defaults.skybox_create(gfx, SKYBOX_PATH)
	defaults.skybox_add_to_scene(&state.scene, &state.skybox)

	// Ground with a pit at x in [-4, 0].
	proto_box(state, gfx, {-9, -1, 0}, {5, 1, 2}, .Ground)
	proto_box(state, gfx, {7, -1, 0}, {7, 1, 2}, .Ground)

	// Ramp rising to the right on the left ground.
	proto_piece(state, gfx, {{-6, 0}, {0, 0}, {0, 4}}, 4, {-8, 0, 0}, .Ramp)

	// Trapezoid step rising out of the right ground.
	proto_piece(state, gfx, {{-1.5, 0}, {1.5, 0}, {0.8, 3}, {-0.8, 3}}, 2, {4, 0, 0}, .Trapezoid)

	// Floating platforms and an inverted trapezoid overhang.
	proto_box(state, gfx, {-3, 2, 0}, {1.5, 0.3, 1.5}, .Platform)
	proto_box(state, gfx, {1, 3.5, 0}, {1.5, 0.3, 1.5}, .Platform)
	proto_box(state, gfx, {4.5, 5, 0}, {1.5, 0.3, 1.5}, .Platform)
	proto_piece(state, gfx, {{-2, 0.8}, {2, 0.8}, {1.2, -0.8}, {-1.2, -0.8}}, 2, {9, 6, 0}, .Trapezoid)

	// Stairs up to the goal.
	for k in 0 ..< 3 {
		h := f32(k + 1)
		proto_box(state, gfx, {9 + 1.5 * f32(k), h / 2, 0}, {0.75, h / 2, 2}, .Ground)
	}
	proto_box(state, gfx, {13.8, 2, 0}, {0.4, 2, 1}, .Goal)

	state.player = proto_box(state, gfx, {0, 0, 0}, {0.5, 0.5, 0.5}, .Player)
	return true
}

platform_tick :: proc(demo: ^Scene, gfx: ^gbbfx.Gfx, delta_time: f32) {
	state := cast(^Platform_State)demo.state
	fly_camera_tick(&state.fly_camera, gfx, delta_time)

	// Player hops between the two left platforms (prototype motion, no physics).
	state.time += delta_time
	s := (math.sin(state.time * 1.2) + 1) / 2
	x := -3 + 4 * s
	y := (2.8 + (4.3 - 2.8) * s) + 1.2 * 4 * s * (1 - s)
	gbbfx.entity_set_position(gbbfx.scene_entity(&state.scene, state.player), {x, y, 0})

	gbbfx.gfx_render(gfx, &state.scene)
}

platform_destroy :: proc(demo: ^Scene, gfx: ^gbbfx.Gfx) {
	state := cast(^Platform_State)demo.state
	gbbfx.scene_destroy(&state.scene)
	defaults.skybox_destroy(gfx, &state.skybox)
	for mesh in state.meshes {
		gbbfx.mesh_destroy(gfx, mesh)
		free(mesh)
	}
	for &solid in state.solids {
		delete(solid.verts)
		delete(solid.idx)
	}
	delete(state.solids)
	delete(state.meshes)
	for &material in state.materials do gbbfx.material_destroy(&material)
	for texture in state.textures do gbbfx.gfx_texture_destroy(gfx, texture)
	gbbfx.gfx_sampler_destroy(gfx, state.sampler)
	gbbfx.gfx_pipeline_destroy(gfx, state.pipeline)
	free(state)
}

// Axis-aligned box centred at `center` with half extents `half`.
proto_box :: proc(
	state: ^Platform_State,
	gfx: ^gbbfx.Gfx,
	center, half: [3]f32,
	material: Proto_Material,
) -> int {
	poly := [4][2]f32{{-half.x, -half.y}, {half.x, -half.y}, {half.x, half.y}, {-half.x, half.y}}
	return proto_piece(state, gfx, poly[:], half.z * 2, center, material)
}

// Convex XY polygon (local to `at`, centred on z = 0) extruded by `depth`.
proto_piece :: proc(
	state: ^Platform_State,
	gfx: ^gbbfx.Gfx,
	poly: [][2]f32,
	depth: f32,
	at: [3]f32,
	material: Proto_Material,
) -> int {
	solid: Proto_Solid
	proto_prism(&solid, poly, depth)
	append(&state.solids, solid)
	stored := &state.solids[len(state.solids) - 1]

	mesh := new(gbbfx.Mesh)
	mesh^ = gbbfx.mesh_create(gfx, stored.verts[:], stored.idx[:])
	gbbfx.mesh_upload(&gfx.renderer, mesh)
	append(&state.meshes, mesh)

	index := gbbfx.scene_add_entity(&state.scene)
	entity := gbbfx.scene_entity(&state.scene, index)
	gbbfx.entity_set_position(entity, at)
	gbbfx.entity_add_renderable(entity, mesh, &state.materials[material])
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
	v := linalg.normalize(linalg.cross(normal, u))
	base := u32(len(solid.verts))
	for p in pts {
		d := p - pts[0]
		append(
			&solid.verts,
			gbbfx.VertexData {
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
