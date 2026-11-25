package engine

import "core:testing"

@(test)
test_screenshot_file_name :: proc(t: ^testing.T) {
	testing.expect_value(t, screenshot_file_name("city", 2026, 11, 25, 14, 30, 0), "shots/city-20261125-143000.png")
	testing.expect_value(t, screenshot_file_name("my scene/a\\b", 2026, 1, 2, 3, 4, 5), "shots/my_scene_a_b-20260102-030405.png")
}
