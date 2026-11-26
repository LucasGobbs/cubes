package city

import "core:testing"

// Values of shaders/constants.json. The generated file is the source of truth: this only guards against a
// hand edit of constants_generated.odin or a value change that forgot the shaders (re-run make constants).
@(test)
test_generated_constants :: proc(t: ^testing.T) {
	testing.expect_value(t, CITY_W, 3072)
	testing.expect_value(t, CITY_D, 2048)
	testing.expect_value(t, SKY_W, 2048)
	testing.expect_value(t, SKY_H, 512)
	testing.expect_value(t, TILE_COUNT_SIDE, 6)
	testing.expect_value(t, TILE_PX, 512)
	testing.expect_value(t, WINDOW_PX, 8)
	testing.expect_value(t, TILE_COUNT, 36)
	testing.expect_value(t, ATLAS_SIZE, 3072)
	testing.expect_value(t, TILE_WINDOWS, 64)
}
