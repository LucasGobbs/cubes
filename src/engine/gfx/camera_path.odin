package gfx

import "core:math"
import "core:math/linalg"

// Camera path: keys {time, position, target}. Position and target are each a centripetal Catmull-Rom curve
// (alpha 0.5, Barry-Goldman form, knots from chord length^0.5) through the keys, parameterised by time: each
// segment maps its local time to the curve. ease applies smootherstep to that local time, so speed is zero at
// every key. Ends are extended with mirrored phantom keys and time is clamped to [first, last].

Camera_Key :: struct {
	time:     f32, // seconds; strictly increasing along a path
	position: Vec3,
	target:   Vec3, // point looked at; yaw/pitch are derived from it
}

Camera_Path :: struct {
	keys: []Camera_Key,
	ease: bool,
}

// Knot spacing for a chord; the floor keeps coincident keys from dividing by zero.
@(private = "file")
path_knot_step :: proc(a, b: Vec3) -> f32 {
	return max(math.sqrt(linalg.length(b - a)), 1e-4)
}

// Key point, mirrored past both ends (phantom key 2*end - neighbour).
@(private = "file")
path_key_point :: proc(keys: []Camera_Key, j: int, use_target: bool) -> Vec3 {
	point :: proc(k: Camera_Key, use_target: bool) -> Vec3 {
		return use_target ? k.target : k.position
	}
	n := len(keys)
	if j < 0 do return 2 * point(keys[0], use_target) - point(keys[1], use_target)
	if j >= n do return 2 * point(keys[n - 1], use_target) - point(keys[n - 2], use_target)
	return point(keys[j], use_target)
}

// Point on segment i..i+1 at local parameter u in [0, 1] (u = 0 gives key i, u = 1 gives key i+1).
@(private = "file")
path_segment_point :: proc(keys: []Camera_Key, i: int, u: f32, use_target: bool) -> Vec3 {
	p0 := path_key_point(keys, i - 1, use_target)
	p1 := path_key_point(keys, i, use_target)
	p2 := path_key_point(keys, i + 1, use_target)
	p3 := path_key_point(keys, i + 2, use_target)
	t0: f32 = -path_knot_step(p0, p1)
	t1: f32 = 0
	t2 := path_knot_step(p1, p2)
	t3 := t2 + path_knot_step(p2, p3)
	s := u * t2

	// Barry-Goldman pyramid: three linear blends, then two, then one.
	a1 := (t1 - s) / (t1 - t0) * p0 + (s - t0) / (t1 - t0) * p1
	a2 := (t2 - s) / (t2 - t1) * p1 + (s - t1) / (t2 - t1) * p2
	a3 := (t3 - s) / (t3 - t2) * p2 + (s - t2) / (t3 - t2) * p3
	b1 := (t2 - s) / (t2 - t0) * a1 + (s - t0) / (t2 - t0) * a2
	b2 := (t3 - s) / (t3 - t1) * a2 + (s - t1) / (t3 - t1) * a3
	return (t2 - s) / (t2 - t1) * b1 + (s - t1) / (t2 - t1) * b2
}

@(private = "file")
path_smootherstep :: proc(u: f32) -> f32 {
	return u * u * u * (u * (u * 6 - 15) + 10)
}

// Camera pose at time t (seconds). Clamps to the first/last key; one key is a fixed pose; no keys returns zeros.
camera_path_sample :: proc(path: Camera_Path, t: f32) -> (position, target: Vec3) {
	keys := path.keys
	last := len(keys) - 1
	switch {
	case last < 0:
		return
	case last == 0 || t <= keys[0].time:
		return keys[0].position, keys[0].target
	case t >= keys[last].time:
		return keys[last].position, keys[last].target
	}
	i := 0
	for i + 1 < last && t >= keys[i + 1].time do i += 1
	u := (t - keys[i].time) / (keys[i + 1].time - keys[i].time)
	if path.ease do u = path_smootherstep(u)
	return path_segment_point(keys, i, u, false), path_segment_point(keys, i, u, true)
}

// Sets position and orientation so the camera looks from position toward target (no change of lens).
// A target equal to position keeps the current orientation.
camera_look_at_pose :: proc(camera: ^Camera, position, target: Vec3) {
	camera.position = position
	look := target - position
	if linalg.length(look) == 0 do return
	look = linalg.normalize(look)
	camera_set_angles(camera, math.atan2(look.z, look.x), math.asin(look.y))
}
