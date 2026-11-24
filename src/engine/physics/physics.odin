package physics

import b3 "vendor:box3d"
import "core:math/linalg"

// Thin wrapper over Box3D. Owns one world; bodies are plain ids the caller keeps.
World :: struct {
	id: b3.WorldId,
}

// Creates a world with the given gravity (Y-up). workers 1 = serial (default); >1 enables the
// Box3D scheduler, which only pays off with hundreds of bodies.
create :: proc(gravity := b3.Vec3{0, -10, 0}, workers := 1) -> World {
	def := b3.DefaultWorldDef()
	def.gravity = gravity
	def.workerCount = u32(workers)
	return World{id = b3.CreateWorld(def)}
}

// Destroys the world and every body/shape in it.
destroy :: proc(w: World) {
	b3.DestroyWorld(w.id)
}

// Advances the simulation by dt seconds using sub_steps solver substeps.
step :: proc(w: World, dt: f32, sub_steps := 4) {
	b3.World_Step(w.id, dt, i32(sub_steps))
}

// Static box centered at pos with the given half extents.
body_static :: proc(w: World, pos: b3.Vec3, half: b3.Vec3) -> b3.BodyId {
	bd := b3.DefaultBodyDef()
	bd.type = .staticBody
	bd.position = b3.ToPos(pos)
	id := b3.CreateBody(w.id, bd)
	add_box_shape(id, half, 1)
	return id
}

// Static box whose top face sits at y, centered on x/z = 0.
body_ground :: proc(w: World, half_extents: b3.Vec3, y := f32(0)) -> b3.BodyId {
	return body_static(w, {0, y - half_extents.y, 0}, half_extents)
}

// Frees the body and its shapes.
body_destroy :: proc(id: b3.BodyId) {
	b3.DestroyBody(id)
}

// Dynamic box centered at pos with the given half extents and density.
body_box :: proc(w: World, pos: b3.Vec3, half: b3.Vec3, density := f32(1)) -> b3.BodyId {
	bd := b3.DefaultBodyDef()
	bd.type = .dynamicBody
	bd.position = b3.ToPos(pos)
	id := b3.CreateBody(w.id, bd)
	add_box_shape(id, half, density)
	return id
}

// Dynamic sphere centered at pos with the given radius and density.
body_sphere :: proc(w: World, pos: b3.Vec3, radius: f32, density := f32(1)) -> b3.BodyId {
	bd := b3.DefaultBodyDef()
	bd.type = .dynamicBody
	bd.position = b3.ToPos(pos)
	id := b3.CreateBody(w.id, bd)
	sd := b3.DefaultShapeDef()
	sd.density = density
	sphere := b3.Sphere{radius = radius}
	_ = b3.CreateSphereShape(id, sd, &sphere)
	return id
}

// Current world position and rotation of a body.
body_pose :: proc(id: b3.BodyId) -> (pos: [3]f32, rot: quaternion128) {
	return b3.ToVec3(b3.Body_GetPosition(id)), b3.Body_GetRotation(id)
}

// Body pose at one physics step.
Pose :: struct {
	pos: [3]f32,
	rot: quaternion128,
}

// Body with its last two poses; render blends prev -> curr between fixed steps.
Tracked :: struct {
	body:       b3.BodyId,
	prev, curr: Pose,
}

// Starts tracking with prev = curr = the current pose.
track :: proc(id: b3.BodyId) -> Tracked {
	pos, rot := body_pose(id)
	p := Pose{pos, rot}
	return Tracked{body = id, prev = p, curr = p}
}

// Call AFTER each step: prev takes the old curr, curr samples the new pose.
// (After, not before: curr is then the latest simulated state, not one tick behind.)
tracked_snapshot :: proc(t: ^Tracked) {
	t.prev = t.curr
	pos, rot := body_pose(t.body)
	t.curr = Pose{pos, rot}
}

// Pose at alpha in [0, 1]: alpha 0 = prev, 1 = curr.
tracked_blend :: proc(t: Tracked, alpha: f32) -> (pos: [3]f32, rot: quaternion128) {
	pos = t.prev.pos + (t.curr.pos - t.prev.pos) * alpha
	rot = linalg.quaternion_slerp(t.prev.rot, t.curr.rot, alpha)
	return
}

// Attaches a box collider (Box3D has no box-shape call; box is a hull) to body id.
@(private = "file")
add_box_shape :: proc(id: b3.BodyId, half: b3.Vec3, density: f32) {
	sd := b3.DefaultShapeDef()
	sd.density = density
	hull := b3.MakeBoxHull(half.x, half.y, half.z)
	_ = b3.CreateHullShape(id, sd, &hull.base)
}
