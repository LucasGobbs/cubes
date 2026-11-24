package engine

import "core:testing"

@(test)
scene_title_alpha_fades_out_at_end :: proc(t: ^testing.T) {
	testing.expect_value(t, scene_title_alpha(0, 2.5), f32(1))
	testing.expect_value(t, scene_title_alpha(2.0, 2.5), f32(1)) // the fade starts 0.5 s before the end
	testing.expect_value(t, scene_title_alpha(2.25, 2.5), f32(0.5))
	testing.expect_value(t, scene_title_alpha(2.5, 2.5), f32(0))
	testing.expect_value(t, scene_title_alpha(3, 2.5), f32(0))
}

@(test)
scene_title_expires_and_restarts :: proc(t: ^testing.T) {
	scene_title_show("first", "", 1)
	scene_title_advance(0.5)
	testing.expect(t, scene_title.active)
	scene_title_advance(0.5)
	testing.expect(t, !scene_title.active)

	scene_title_show("second", "sub", 1)
	testing.expect(t, scene_title.active)
	testing.expect_value(t, scene_title.elapsed, f32(0))
	testing.expect_value(t, scene_title.text, "second")
	testing.expect_value(t, scene_title.subtitle, "sub")

	delete(scene_title.text)
	delete(scene_title.subtitle)
	scene_title = {}
}
