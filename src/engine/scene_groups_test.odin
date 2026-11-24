package engine

import "core:slice"
import "core:testing"

@(test)
scene_groups_bucket_by_first_appearance :: proc(t: ^testing.T) {
	entries := [?]Scene_Entry {
		{name = "boat", group = "sea"},
		{name = "forest", group = "forest"},
		{name = "bench", group = "sea"},
		{name = "script"}, // no group: a group of its own
		{name = "reef", group = "sea"},
	}
	groups := scene_groups_build(entries[:])
	defer scene_groups_destroy(&groups)

	testing.expect_value(t, len(groups.names), 3)
	testing.expect_value(t, groups.names[0], "sea")
	testing.expect_value(t, groups.names[1], "forest")
	testing.expect_value(t, groups.names[2], "script")
	testing.expect(t, slice.equal(groups.group_of, []int{0, 1, 0, 2, 0}), "group_of")
	testing.expect(t, slice.equal(groups.position, []int{0, 0, 1, 0, 2}), "position")
	testing.expect(t, slice.equal(groups.members[0], []int{0, 2, 4}), "members of sea")
	testing.expect_value(t, groups.last[0], 0)
}

@(test)
scene_groups_visit_remembers_last_scene :: proc(t: ^testing.T) {
	entries := [?]Scene_Entry{{name = "a", group = "g"}, {name = "b", group = "g"}, {name = "c"}}
	groups := scene_groups_build(entries[:])
	defer scene_groups_destroy(&groups)

	scene_groups_visit(&groups, 1)
	testing.expect_value(t, groups.last[0], 1)
	testing.expect_value(t, groups.last[1], 2)
}

@(test)
group_step_wraps :: proc(t: ^testing.T) {
	testing.expect_value(t, group_next(0, 3), 1)
	testing.expect_value(t, group_next(2, 3), 0)
	testing.expect_value(t, group_prev(0, 3), 2)
	testing.expect_value(t, group_prev(1, 3), 0)
	testing.expect_value(t, group_next(0, 1), 0)
}
