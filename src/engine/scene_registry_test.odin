package engine

import "core:testing"

@(private = "file")
bare_scene :: proc() -> Scene {
	return {name = "Bare"}
}

// A code scene without scene.json keeps its built-in defaults. A missing file must
// not log an error: odin test fails on log.errorf.
@(test)
code_scene_without_file_uses_defaults :: proc(t: ^testing.T) {
	entries := [?]Scene_Entry{{name = "__no_scene_json__", make = bare_scene}}
	scene, found := scene_lookup(entries[:], "__no_scene_json__")
	testing.expect(t, found)
	testing.expect_value(t, scene.name, "Bare")
}
