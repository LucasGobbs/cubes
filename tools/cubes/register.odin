// Text edits on src/scene.odin and scene files. Pure: string in, string out, no IO.
// Edits insert before markers, so existing lines and their order never change.
package main

import "core:strings"

MARK_IMPORTS :: "// cubes:imports"
MARK_SCENES :: "// cubes:scenes"
MARK_ACTORS :: "// cubes:actors"

SCENES_OPEN :: "SCENES := [?]engine.Scene_Entry {"

// Registers a scene in the registry source. Code scenes get an import; both get a SCENES
// entry appended after the existing ones. Markers are added on first use. On failure
// out is "" and err says why; nothing is guessed.
registry_add_scene :: proc(src, name: string, data: bool) -> (out, err: string) {
	if strings.contains(src, join("name = \"", name, "\"")) || strings.contains(src, join("\"scenes/", name, "\"")) {
		return "", join("scene ", name, " is already registered in src/scene.odin")
	}
	lines := strings.split(src, "\n", context.temp_allocator)
	open := find_trimmed(lines, SCENES_OPEN, 0, len(lines))
	if open < 0 do return "", "src/scene.odin: SCENES array not recognised, add the markers by hand"
	close := find_trimmed(lines, "}", open + 1, len(lines))
	if close < 0 do return "", "src/scene.odin: SCENES closing brace not found"
	last_import := -1
	for i in 0 ..< open do if strings.has_prefix(lines[i], "import ") do last_import = i
	if !data && last_import < 0 do return "", "src/scene.odin: no import lines found"

	// Edit bottom-up: the SCENES edit sits below the imports, so earlier indices stay valid.
	entry := join("\t{name = \"", name, "\", make = ", name, ".", name, "_scene},")
	if data do entry = join("\t{name = \"", name, "\"},")
	marker := find_trimmed(lines, MARK_SCENES, open, close)
	if marker >= 0 {
		lines = splice(lines, marker, {entry})
	} else {
		lines = splice(lines, close, {entry, MARK_SCENES})
	}

	if !data {
		import_line := join("import ", name, " \"scenes/", name, "\"")
		marker = find_trimmed(lines, MARK_IMPORTS, 0, open)
		if marker >= 0 {
			lines = splice(lines, marker, {import_line})
		} else {
			lines = splice(lines, last_import + 1, {import_line, MARK_IMPORTS})
		}
	}
	return strings.join(lines, "\n", context.temp_allocator), ""
}

// Wires an actor into a scene file: its spawn line goes before the `// cubes:actors` marker.
// Scene files without the marker get it inside create, before `return true`.
// ok=false: the structure is not recognised; src is returned unchanged.
scene_add_actor :: proc(src, scene, actor: string) -> (out: string, ok: bool) {
	lines := strings.split(src, "\n", context.temp_allocator)
	marker := find_trimmed(lines, MARK_ACTORS, 0, len(lines))
	if marker < 0 {
		create_at := find_prefix(lines, join(scene, "_create :: proc("), 0, len(lines))
		if create_at < 0 do return src, false
		ret := find_trimmed(lines, "return true", create_at, len(lines))
		if ret < 0 do return src, false
		lines = splice(lines, ret, {join("\t", MARK_ACTORS)})
		marker = ret
	}
	lines = splice(lines, marker, {actor_wiring(actor)})
	return strings.join(lines, "\n", context.temp_allocator), true
}

// The line that spawns an actor, indented for a create body.
actor_wiring :: proc(actor: string) -> string {
	return join("\t", actor, "_spawn(&state.world)")
}

// Trimmed exact match in lines[from:to]; -1 when absent.
find_trimmed :: proc(lines: []string, want: string, from, to: int) -> int {
	for i in from ..< to do if strings.trim_space(lines[i]) == want do return i
	return -1
}

// Line in lines[from:to] that starts with prefix (no trim); -1 when absent.
find_prefix :: proc(lines: []string, prefix: string, from, to: int) -> int {
	for i in from ..< to do if strings.has_prefix(lines[i], prefix) do return i
	return -1
}

// Inserts new before lines[at]; at == len(lines) appends.
splice :: proc(lines: []string, at: int, new: []string) -> []string {
	out := make([dynamic]string, 0, len(lines) + len(new), context.temp_allocator)
	append_elems(&out, ..lines[:at])
	append_elems(&out, ..new)
	append_elems(&out, ..lines[at:])
	return out[:]
}

join :: proc(parts: ..string) -> string {
	return strings.concatenate(parts, context.temp_allocator)
}
