package gfx

import "core:math/linalg"
import "core:testing"

@(test)
camera_path_passes_through_keys :: proc(t: ^testing.T) {
	keys := [?]Camera_Key {
		{time = 0, position = {0, 0, 0}, target = {0, 0, -10}},
		{time = 2, position = {5, 1, 3}, target = {5, 0, -7}},
		{time = 3, position = {9, 4, -2}, target = {12, 0, -5}},
		{time = 7, position = {-4, 2, 6}, target = {0, 1, 0}},
	}
	for ease in ([2]bool{false, true}) {
		path := Camera_Path{keys = keys[:], ease = ease}
		for k in keys {
			p, tg := camera_path_sample(path, k.time)
			testing.expect(t, linalg.length(p - k.position) < 1e-3)
			testing.expect(t, linalg.length(tg - k.target) < 1e-3)
		}
	}
}

@(test)
camera_path_clamps_and_single_key_is_fixed :: proc(t: ^testing.T) {
	keys := [?]Camera_Key{{time = 1, position = {1, 2, 3}, target = {4, 5, 6}}, {time = 3, position = {7, 8, 9}, target = {0, 0, 0}}}
	path := Camera_Path{keys = keys[:], ease = true}
	p, tg := camera_path_sample(path, -5)
	testing.expect(t, p == keys[0].position && tg == keys[0].target)
	p, tg = camera_path_sample(path, 100)
	testing.expect(t, p == keys[1].position && tg == keys[1].target)

	one := Camera_Path{keys = keys[:1]}
	for time in ([3]f32{-1, 1.5, 50}) {
		p, tg = camera_path_sample(one, time)
		testing.expect(t, p == keys[0].position && tg == keys[0].target)
	}
}

@(test)
camera_path_is_monotonic_on_a_line :: proc(t: ^testing.T) {
	keys := [?]Camera_Key {
		{time = 0, position = {0, 0, 0}, target = {0, 0, 0}},
		{time = 1, position = {10, 0, 0}, target = {10, 0, 0}},
		{time = 2, position = {20, 0, 0}, target = {20, 0, 0}},
		{time = 3, position = {30, 0, 0}, target = {30, 0, 0}},
	}
	for ease in ([2]bool{false, true}) {
		path := Camera_Path{keys = keys[:], ease = ease}
		prev := f32(-1)
		for step in 0 ..= 300 {
			p, _ := camera_path_sample(path, f32(step) * 0.01)
			testing.expect(t, p.x >= prev - 1e-5)
			testing.expect(t, p.x >= -1e-4 && p.x <= 30 + 1e-4)
			prev = p.x
		}
	}
}
