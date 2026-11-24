// Scene groups: registry entries bucketed by Scene_Entry.group, groups in order of first
// appearance. Number keys pick a group; Q/E step within the current one. Each group
// remembers the scene last shown in it. Pure data, no Device.
package engine

Scene_Groups :: struct {
	names:    []string, // group names, borrowed from the entries
	members:  [][]int, // scene indices per group, in entry order
	group_of: []int, // group index per scene index
	position: []int, // index of each scene within its group
	last:     []int, // scene index last shown in each group
}

// Group of an entry: its group field, or its own name when empty.
scene_group_name :: proc(entry: Scene_Entry) -> string {
	return entry.group if entry.group != "" else entry.name
}

scene_groups_build :: proc(entries: []Scene_Entry, allocator := context.allocator) -> Scene_Groups {
	context.allocator = allocator
	groups: Scene_Groups
	names: [dynamic]string
	defer delete(names)
	groups.group_of = make([]int, len(entries))
	groups.position = make([]int, len(entries))
	for entry, scene in entries {
		name := scene_group_name(entry)
		group := -1
		for known, g in names do if known == name {
			group = g
			break
		}
		if group < 0 {
			append(&names, name)
			group = len(names) - 1
		}
		groups.group_of[scene] = group
	}

	counts := make([]int, len(names))
	defer delete(counts)
	for group in groups.group_of do counts[group] += 1

	groups.names = make([]string, len(names))
	groups.members = make([][]int, len(names))
	groups.last = make([]int, len(names))
	for name, g in names {
		groups.names[g] = name
		groups.members[g] = make([]int, counts[g])
	}
	filled := make([]int, len(names))
	defer delete(filled)
	for group, scene in groups.group_of {
		groups.position[scene] = filled[group]
		groups.members[group][filled[group]] = scene
		filled[group] += 1
	}
	for members, g in groups.members do groups.last[g] = members[0]
	return groups
}

scene_groups_destroy :: proc(groups: ^Scene_Groups, allocator := context.allocator) {
	context.allocator = allocator
	for members in groups.members do delete(members)
	delete(groups.members)
	delete(groups.names)
	delete(groups.group_of)
	delete(groups.position)
	delete(groups.last)
	groups^ = {}
}

// Records that `scene` is the one shown for its group.
scene_groups_visit :: proc(groups: ^Scene_Groups, scene: int) {
	groups.last[groups.group_of[scene]] = scene
}

// Position after one step within a group of `count` scenes (wraps).
group_next :: proc(position, count: int) -> int {
	return (position + 1) % count
}

group_prev :: proc(position, count: int) -> int {
	return (position + count - 1) % count
}
