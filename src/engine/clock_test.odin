package engine

import "core:testing"

@(test)
test_clock_fixed_step :: proc(t: ^testing.T) {
	clock := Clock{fixed_dt = 1.0 / 60.0}
	for _ in 0 ..< 60 do clock_update(&clock)
	testing.expect_value(t, clock.delta, f32(1.0 / 60.0))
	testing.expect(t, abs(clock.time - 1.0) < 1e-4)
}
