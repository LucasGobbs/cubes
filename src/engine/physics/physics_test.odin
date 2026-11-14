package physics

import "core:testing"
import "core:math/linalg"
import b3 "vendor:box3d"

// One @(test) on purpose: box3d keeps pools per world but a global b3_worlds array created
// without a lock, so creating worlds on parallel test threads races. Scenarios run in sequence.
@(test)
physics_scenarios :: proc(t: ^testing.T) {
	sphere_falls_under_gravity(t)
	box_rests_on_ground(t)
	tracked_blend_interpolates(t)
}

sphere_falls_under_gravity :: proc(t: ^testing.T) {
	w := create()
	defer destroy(w)
	id := body_sphere(w, {0, 5, 0}, 0.5)
	for _ in 0 ..< 30 do step(w, 1.0 / 60)
	pos, _ := body_pose(id)
	testing.expect(t, pos.y < 5, "sphere should fall below start y=5")
}

box_rests_on_ground :: proc(t: ^testing.T) {
	w := create()
	defer destroy(w)
	body_ground(w, {10, 0.5, 10})
	half := b3.Vec3{0.5, 0.5, 0.5}
	id := body_box(w, {0, 2, 0}, half)
	for _ in 0 ..< 300 do step(w, 1.0 / 60)
	pos, _ := body_pose(id)
	testing.expect(t, abs(pos.y - half.y) < 0.05, "box should rest with center at half.y above ground top (y=0)")
}

tracked_blend_interpolates :: proc(t: ^testing.T) {
	w := create()
	defer destroy(w)
	id := body_sphere(w, {0, 5, 0}, 0.5)
	tr := track(id)
	step(w, 1.0 / 60)
	tracked_snapshot(&tr)
	p1 := tr.curr.pos
	step(w, 1.0 / 60)
	tracked_snapshot(&tr)
	p2 := tr.curr.pos
	pos0, _ := tracked_blend(tr, 0)
	pos1, _ := tracked_blend(tr, 1)
	pos_mid, _ := tracked_blend(tr, 0.5)
	testing.expect(t, linalg.length(pos0 - p1) < 1e-5, "alpha 0 should be prev")
	testing.expect(t, linalg.length(pos1 - p2) < 1e-5, "alpha 1 should be curr")
	testing.expect(t, linalg.length(pos_mid - (p1 + p2) * 0.5) < 1e-5, "alpha 0.5 should be midpoint")
}
