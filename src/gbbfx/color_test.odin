package gbbfx

import "core:math"
import "core:testing"

@(test)
srgb_to_linear_matches_the_standard_curve :: proc(t: ^testing.T) {
	testing.expect_value(t, srgb_to_linear(0), 0)
	testing.expect(t, math.abs(srgb_to_linear(1) - 1) < 1e-6)
	testing.expect(t, math.abs(srgb_to_linear(0.5) - 0.21404) < 1e-4) // the mid-gray from the guide
	testing.expect(t, math.abs(srgb_to_linear(0.02) - 0.02 / 12.92) < 1e-7) // linear toe
	testing.expect_value(t, color_srgb_to_linear({1, 1, 1, 0.5}).a, 0.5)
}

@(test)
mip_level_count_covers_chain_to_one_texel :: proc(t: ^testing.T) {
	testing.expect_value(t, mip_level_count(1, 1), u32(1))
	testing.expect_value(t, mip_level_count(512, 512), u32(10))
	testing.expect_value(t, mip_level_count(4096, 2048), u32(13))
	testing.expect_value(t, mip_level_count(300, 100), u32(9)) // non power of two: floor(log2(300)) + 1
}
