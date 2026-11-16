// Physics for both forests: a ball rolls on the terrain and hits trees.
// Colliders cover only the centre region; the ball falls off beyond it.
package forest_naive

import "core:math"
import "core:math/linalg"
import b3 "vendor:box3d"
import gfx "../../engine/gfx"
import phys "../../engine/physics"

// shortcut: colliders cover [-80, 80]^2 only; ball falls forever beyond it, widen if needed
COLLIDER_HALF :: 80.0
COLLIDER_CELLS :: 160 // 1 m grid, same points as the visual terrain
COLLIDER_CHUNK0 :: int((WORLD_HALF - COLLIDER_HALF) / CHUNK_SIZE)
COLLIDER_CHUNKS :: int(2 * COLLIDER_HALF / CHUNK_SIZE)

BALL_RADIUS :: 0.5
BALL_SPAWN_HEIGHT :: 6.0
BALL_LAUNCH_SPEED :: 12.0
BALL_RINGS :: 12
BALL_MAX :: 8 // simultaneous balls; launch past this reuses the oldest slot
BALL_SEGMENTS :: 16
ROCK_COLLIDER_RADIUS :: 0.8 // rock sphere radius per unit: placements scale, mesh blob r

// Which tree colliders to build: placements (forest_instanced) or the mesher's trees (forest_naive).
Collider_Source :: enum {
	Placements,
	Mesh,
}

Ball :: struct {
	track: phys.Tracked,
	draw:  int,
}

// Owned by a scene state; `material` must outlive it (it points into the scene state).
Physics :: struct {
	world:            phys.World,
	terrain_collider: ^b3.HeightFieldData,
	balls:            [BALL_MAX]Ball,
	ball_count:       int, // slots in use, filled in order
	ball_next:        int, // oldest slot, reused once full
	ball_mesh:        gfx.Mesh,
	material:         ^gfx.Material,
}

// Sets up the Box3D world (only one may exist at a time) and all static colliders.
physics_create :: proc(state: ^Physics, gfx_ctx: ^gfx.Device, material: ^gfx.Material, source: Collider_Source) {
	state.world = phys.create()
	state.material = material
	physics_terrain_create(state)
	physics_trees_create(state, source)
	spawn := b3.Vec3{0, terrain_height(0, -4) + BALL_SPAWN_HEIGHT, -4}
	state.ball_mesh = ball_mesh_create(gfx_ctx)
	ball_create(state, gfx_ctx, spawn)
}

physics_destroy :: proc(state: ^Physics, gfx_ctx: ^gfx.Device) {
	phys.destroy(state.world)
	b3.DestroyHeightField(state.terrain_collider) // shape only references it; free after world
	gfx.mesh_destroy(gfx_ctx, &state.ball_mesh)
}

// Advances the world by one fixed step and snapshots ball poses for blending.
physics_step :: proc(state: ^Physics, dt: f32) {
	phys.step(state.world, dt)
	for &ball in state.balls[:state.ball_count] do phys.tracked_snapshot(&ball.track)
}

// Draws every ball at the pose blended between the last two fixed steps.
physics_draw :: proc(state: ^Physics, gfx_ctx: ^gfx.Device, blend: f32) {
	for ball in state.balls[:state.ball_count] {
		ball_pos, ball_rot := phys.tracked_blend(ball.track, blend)
		gfx.draw_move(gfx_ctx, ball.draw, ball_pos, ball_rot, {1, 1, 1})
	}
}

// Heightfield over the centre region, sampled from the same terrain_height as the visual mesh.
physics_terrain_create :: proc(state: ^Physics) {
	n := COLLIDER_CELLS + 1
	heights := make([]f32, n * n)
	defer delete(heights)
	lo, hi := max(f32), min(f32)
	for j in 0 ..< n {
		for i in 0 ..< n {
			h := terrain_height(f32(i) - COLLIDER_HALF, f32(j) - COLLIDER_HALF)
			heights[j * n + i] = h
			lo = min(lo, h)
			hi = max(hi, h)
		}
	}
	materials := make([]u8, COLLIDER_CELLS * COLLIDER_CELLS) // zeroed: default material
	defer delete(materials)

	state.terrain_collider = b3.CreateHeightField(
		b3.HeightFieldDef {
			heights = raw_data(heights),
			materialIndices = raw_data(materials),
			scale = {1, 1, 1},
			countX = i32(n),
			countZ = i32(n),
			globalMinimumHeight = lo,
			globalMaximumHeight = hi,
		},
	)
	body_def := b3.DefaultBodyDef()
	body_def.type = .staticBody
	body_def.position = b3.ToPos({-COLLIDER_HALF, 0, -COLLIDER_HALF})
	body := b3.CreateBody(state.world.id, body_def)
	shape_def := b3.DefaultShapeDef()
	_ = b3.CreateHeightFieldShape(body, shape_def, state.terrain_collider)
}

// One static body holds every tree and rock collider, in world coordinates.
physics_trees_create :: proc(state: ^Physics, source: Collider_Source) {
	body_def := b3.DefaultBodyDef()
	body_def.type = .staticBody
	body := b3.CreateBody(state.world.id, body_def)
	switch source {
	case .Placements:
		instances := make([dynamic]Instance, 0, 64)
		defer delete(instances)
		for cz in COLLIDER_CHUNK0 ..< COLLIDER_CHUNK0 + COLLIDER_CHUNKS {
			for cx in COLLIDER_CHUNK0 ..< COLLIDER_CHUNK0 + COLLIDER_CHUNKS {
				clear(&instances)
				placements_chunk(cx, cz, &instances)
				for inst in instances do physics_collider_add(body, inst)
			}
		}
	case .Mesh:
		physics_mesh_trees_add(body)
	}
}

// Trunks are vertical capsules (canopy has no collider), rocks are spheres,
// bushes have no collider (ball rolls over them).
physics_collider_add :: proc(body: b3.BodyId, inst: Instance) {
	shape_def := b3.DefaultShapeDef()
	switch {
	case inst.variant >= VARIANT_BUSH_FIRST:
		return
	case inst.variant >= VARIANT_ROCK_FIRST:
		sphere := b3.Sphere{center = inst.position, radius = ROCK_COLLIDER_RADIUS * inst.scale}
		_ = b3.CreateSphereShape(body, shape_def, &sphere)
	case:
		radius, height: f32 = 0.45, 3.2 // oak and autumn
		switch {
		case inst.variant >= VARIANT_BROAD_FIRST && inst.variant < VARIANT_AUTUMN:
			radius, height = 0.5, 8.0
		case inst.variant >= VARIANT_PINE_FIRST && inst.variant < VARIANT_BROAD_FIRST:
			radius, height = 0.2, 7.0
		}
		p := inst.position
		capsule := b3.Capsule {
			center1 = p,
			center2 = {p.x, p.y + height * inst.scale, p.z},
			radius  = radius * inst.scale,
		}
		_ = b3.CreateCapsuleShape(body, shape_def, &capsule)
	}
}

// Colliders from the mesher's own trees: trunk capsules and rock spheres as recorded by
// trees_chunk, for every chunk in the collider region. Same call order as the chunk bake job
// (terrain verts count toward the tree vertex cap), so the set matches the drawn trees.
physics_mesh_trees_add :: proc(body: b3.BodyId) {
	verts := make([dynamic]gfx.VertexData, 0, 4096)
	idx := make([dynamic]u32, 0, 8192)
	cols := make([dynamic]Tree_Collider, 0, 64)
	defer delete(verts)
	defer delete(idx)
	defer delete(cols)
	for cz in COLLIDER_CHUNK0 ..< COLLIDER_CHUNK0 + COLLIDER_CHUNKS {
		for cx in COLLIDER_CHUNK0 ..< COLLIDER_CHUNK0 + COLLIDER_CHUNKS {
			clear(&verts)
			clear(&idx)
			clear(&cols)
			terrain_chunk(cx, cz, &verts, &idx)
			trees_chunk(cx, cz, &verts, &idx, &cols)
			for c in cols do physics_mesh_collider_add(body, c)
		}
	}
}

// Trunk: capsule along the real (bent) trunk axis, radius = waist radius (flare ignored).
// Rock: sphere at blob centre, radius = ROCK_COLLIDER_RADIUS x blob radius (blob is 0.6 r tall).
physics_mesh_collider_add :: proc(body: b3.BodyId, c: Tree_Collider) {
	shape_def := b3.DefaultShapeDef()
	switch c.kind {
	case .Trunk:
		capsule := b3.Capsule{center1 = c.p0, center2 = c.p1, radius = c.radius}
		_ = b3.CreateCapsuleShape(body, shape_def, &capsule)
	case .Rock:
		sphere := b3.Sphere{center = c.p0, radius = ROCK_COLLIDER_RADIUS * c.radius}
		_ = b3.CreateSphereShape(body, shape_def, &sphere)
	}
}

// Adds a ball in slot ball_count; caller ensures ball_count < BALL_MAX.
// shortcut: balls leaving the collider region [-80, 80]^2 fall forever; slots are never freed
ball_create :: proc(state: ^Physics, gfx_ctx: ^gfx.Device, pos: b3.Vec3) {
	ball := &state.balls[state.ball_count]
	ball.track = phys.track(phys.body_sphere(state.world, pos, BALL_RADIUS))
	ball.draw = gfx.draw_create(gfx_ctx, {mesh = &state.ball_mesh, material = state.material, position = pos})
	state.ball_count += 1
}

// Fires a ball from the camera along the view direction: new slot until full, then the oldest is reused.
physics_launch :: proc(state: ^Physics, gfx_ctx: ^gfx.Device) {
	cam := gfx.camera(gfx_ctx)
	forward := cam.direction
	pos := cam.position + forward * 1.5
	slot: int
	if state.ball_count < BALL_MAX {
		slot = state.ball_count
		ball_create(state, gfx_ctx, pos)
	} else {
		slot = state.ball_next
		state.ball_next = (state.ball_next + 1) % BALL_MAX
	}
	body := state.balls[slot].track.body
	b3.Body_SetTransform(body, b3.ToPos(pos), linalg.QUATERNIONF32_IDENTITY)
	state.balls[slot].track = phys.track(body) // reset, so render does not blend through the teleport
	b3.Body_SetLinearVelocity(body, forward * BALL_LAUNCH_SPEED)
	b3.Body_SetAngularVelocity(body, {0, 0, 0})
	b3.Body_SetAwake(body, true)
}

// UV sphere at BALL_RADIUS; built once, freed after upload.
ball_mesh_create :: proc(gfx_ctx: ^gfx.Device) -> gfx.Mesh {
	verts := make([dynamic]gfx.VertexData, 0, (BALL_RINGS + 1) * BALL_SEGMENTS)
	idx := make([dynamic]u32, 0, BALL_RINGS * BALL_SEGMENTS * 6)
	defer delete(verts)
	defer delete(idx)
	for r in 0 ..= BALL_RINGS {
		phi := math.PI * f32(r) / BALL_RINGS
		for s in 0 ..< BALL_SEGMENTS {
			theta := 2 * math.PI * f32(s) / BALL_SEGMENTS
			d := [3]f32{math.sin(phi) * math.cos(theta), math.cos(phi), math.sin(phi) * math.sin(theta)}
			append(&verts, gfx.VertexData{position = d * BALL_RADIUS, color = {0.9, 0.2, 0.15, 1}, normal = d})
		}
	}
	for r in 0 ..< BALL_RINGS {
		for s in 0 ..< BALL_SEGMENTS {
			s1 := (s + 1) % BALL_SEGMENTS
			a := u32(r * BALL_SEGMENTS + s)
			b := u32(r * BALL_SEGMENTS + s1)
			c := u32((r + 1) * BALL_SEGMENTS + s)
			d := u32((r + 1) * BALL_SEGMENTS + s1)
			append(&idx, a, b, c, b, d, c)
		}
	}
	return gfx.mesh_create(gfx_ctx, verts[:], idx[:])
}
