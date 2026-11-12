package default

import "core:testing"
import "core:math"
import gfx "../gfx"

@(test)
camera2d_maps_view_centre_to_ndc_centre :: proc(t: ^testing.T) {
	cam := Camera2D{position = {200, 150}, viewport = {400, 300}}
	m := camera2d_matrix(cam, {800, 600})
	origin := m * [4]f32{0, 0, 0, 1}
	corner := m * [4]f32{400, 300, 0, 1}
	testing.expect(t, math.abs(origin.x + 1) < 1e-3 && math.abs(origin.y - 1) < 1e-3, "world (0,0) -> NDC (-1,1)")
	testing.expect(t, math.abs(corner.x - 1) < 1e-3 && math.abs(corner.y + 1) < 1e-3, "world (400,300) -> NDC (1,-1)")
}

@(test)
camera2d_integer_scale_centres_view_and_maps_back :: proc(t: ^testing.T) {
	cam := Camera2D{position = {200, 150}, viewport = {400, 300}, integer_scale = true}
	centre := screen_to_world(cam, {900, 600}, {450, 300})
	testing.expect(t, math.abs(centre.x - 200) < 1e-3 && math.abs(centre.y - 150) < 1e-3, "window centre -> view centre")
	// scale is 2 (floor(min(900/400, 600/300)) = 2): 2 screen px = 1 world px
	step := screen_to_world(cam, {900, 600}, {452, 300})
	testing.expect(t, math.abs(step.x - 201) < 1e-3, "integer scale 2 px per world px")
}

@(test)
camera2d_round_trip :: proc(t: ^testing.T) {
	window := [2]i32{900, 600}
	for rot in ([]f32{0, 0.3}) {
		cam := Camera2D{position = {37, -12}, zoom = 2, rotation = rot, viewport = {400, 300}}
		p := [2]f32{123.5, 45.25}
		ndc := camera2d_matrix(cam, window) * [4]f32{p.x, p.y, 0, 1}
		screen := [2]f32{(ndc.x + 1) * f32(window.x) / 2, (1 - ndc.y) * f32(window.y) / 2}
		back := screen_to_world(cam, window, screen)
		testing.expect(t, math.abs(back.x - p.x) < 1e-3 && math.abs(back.y - p.y) < 1e-3, "screen_to_world inverts camera2d_matrix")
	}
}

@(test)
batch_sprite_groups_runs_by_texture :: proc(t: ^testing.T) {
	gfx_ctx := gfx.Device{window_size = {800, 600}}
	b: Batch
	defer {
		delete(b.vertices)
		delete(b.runs)
	}
	a := gfx.Texture_Handle(gfx.Resource_Handle{index = 1, generation = 1})
	c := gfx.Texture_Handle(gfx.Resource_Handle{index = 2, generation = 1})
	batch_begin(&b, &gfx_ctx, Camera2D{viewport = {400, 300}})
	size := [2]f32{64, 64}
	batch_sprite(&b, a, size, {0, 0}, {16, 16})
	batch_sprite(&b, a, size, {20, 0}, {16, 16})
	batch_sprite(&b, c, size, {40, 0}, {16, 16})
	batch_sprite(&b, a, size, {60, 0}, {16, 16})
	testing.expect_value(t, len(b.runs), 3)
	testing.expect_value(t, b.sprites, 4)
	testing.expect_value(t, len(b.vertices), 24)
	testing.expect_value(t, b.runs[0].first, 0)
	testing.expect_value(t, b.runs[0].count, 12)
	testing.expect_value(t, b.runs[1].first, 12)
	testing.expect_value(t, b.runs[1].count, 6)
	testing.expect_value(t, b.runs[2].first, 18)
	testing.expect_value(t, b.runs[2].count, 6)
}
