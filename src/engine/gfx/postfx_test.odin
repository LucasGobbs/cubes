package gfx

import "core:testing"

@(test)
bloom_level_size_test :: proc(t: ^testing.T) {
	w, h := bloom_level_size(0, 1280, 780)
	testing.expect_value(t, w, u32(640))
	testing.expect_value(t, h, u32(390))

	w, h = bloom_level_size(1, 1280, 780)
	testing.expect_value(t, w, u32(320))
	testing.expect_value(t, h, u32(195))

	// Eighth rounds up, like the city's old eighth target.
	w, h = bloom_level_size(2, 1281, 781)
	testing.expect_value(t, w, u32(161))
	testing.expect_value(t, h, u32(98))

	w, h = bloom_level_size(2, 1, 1)
	testing.expect_value(t, w, u32(1))
	testing.expect_value(t, h, u32(1))
}
