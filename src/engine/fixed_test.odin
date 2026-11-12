package engine

import "core:testing"

@(test)
fixed_steps_runs_whole_steps_and_keeps_remainder :: proc(t: ^testing.T) {
	acc: f32
	steps, blend := fixed_steps(&acc, 0.05, 1.0 / 60, 5)
	testing.expect_value(t, steps, 3)
	testing.expect(t, blend >= 0 && blend < 1, "blend in [0,1)")
}

@(test)
fixed_steps_caps_and_drops_excess :: proc(t: ^testing.T) {
	acc: f32
	steps, _ := fixed_steps(&acc, 1.0, 1.0 / 60, 5)
	testing.expect_value(t, steps, 5)
	testing.expect_value(t, acc, 0)
}

@(test)
fixed_steps_short_frame_runs_none :: proc(t: ^testing.T) {
	acc: f32
	steps, blend := fixed_steps(&acc, 0.001, 1.0 / 60, 5)
	testing.expect_value(t, steps, 0)
	testing.expect(t, blend > 0.05 && blend < 0.07, "blend ~0.06")
}
