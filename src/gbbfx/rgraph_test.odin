package gbbfx

import "core:testing"

@(test)
pass_size_dims_divides_and_never_drops_below_one :: proc(t: ^testing.T) {
	w, h := pass_size_dims(.Full, 1280, 780)
	testing.expect_value(t, w, u32(1280))
	testing.expect_value(t, h, u32(780))

	w, h = pass_size_dims(.Half, 1280, 780)
	testing.expect_value(t, w, u32(640))
	testing.expect_value(t, h, u32(390))

	w, h = pass_size_dims(.Quarter, 5, 5)
	testing.expect_value(t, w, u32(2))
	testing.expect_value(t, h, u32(2))

	w, h = pass_size_dims(.Quarter, 1, 1)
	testing.expect_value(t, w, u32(1))
	testing.expect_value(t, h, u32(1))
}

@(test)
groups_for_rounds_up_to_the_group_size :: proc(t: ^testing.T) {
	testing.expect_value(t, groups_for(1280, 780), [3]u32{160, 98, 1})
	testing.expect_value(t, groups_for(1, 1), [3]u32{1, 1, 1})
	testing.expect_value(t, groups_for(8, 9), [3]u32{1, 2, 1})
}
