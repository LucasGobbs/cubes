package main

import "core:strings"
import "core:testing"

REGISTRY_NO_MARKERS :: `// Scene registry.
package main

import engine "engine"
import boat "scenes/boat"
import game "scenes/game"

SCENES := [?]engine.Scene_Entry {
	{name = "boat", make = boat.boat_scene},
	{name = "game", make = game.game_scene},
}
`

@(test)
test_registry_adds_markers_and_keeps_order :: proc(t: ^testing.T) {
	first, err := registry_add_scene(REGISTRY_NO_MARKERS, "alpha", false)
	testing.expect_value(t, err, "")
	testing.expect_value(t, strings.count(first, MARK_IMPORTS), 1)
	testing.expect_value(t, strings.count(first, MARK_SCENES), 1)

	second, err2 := registry_add_scene(first, "beta", false)
	testing.expect_value(t, err2, "")
	testing.expect_value(t, strings.count(second, MARK_IMPORTS), 1)
	testing.expect_value(t, strings.count(second, MARK_SCENES), 1)

	// Existing entries stay, in order; each new entry lands after the previous ones.
	boat_at := strings.index(second, `{name = "boat"`)
	game_at := strings.index(second, `{name = "game"`)
	alpha_at := strings.index(second, `{name = "alpha"`)
	beta_at := strings.index(second, `{name = "beta"`)
	testing.expect(t, 0 <= boat_at && boat_at < game_at && game_at < alpha_at && alpha_at < beta_at, "entry order")
	testing.expect(t, strings.contains(second, `import boat "scenes/boat"`), "existing import kept")
	testing.expect(t, strings.contains(second, `import beta "scenes/beta"`), "beta import")
	// Each new line sits directly above its marker.
	testing.expect(t, strings.contains(second, "\t{name = \"beta\", make = beta.beta_scene},\n// cubes:scenes"), "entry above scenes marker")
	testing.expect(t, strings.contains(second, "import beta \"scenes/beta\"\n// cubes:imports"), "import above imports marker")
}

@(test)
test_registry_refuses_duplicate :: proc(t: ^testing.T) {
	out, err := registry_add_scene(REGISTRY_NO_MARKERS, "boat", false)
	testing.expect_value(t, out, "")
	testing.expect(t, strings.contains(err, "already registered"), err)
}

@(test)
test_registry_refuses_unknown_structure :: proc(t: ^testing.T) {
	out, err := registry_add_scene("package main\n\nimport engine \"engine\"\n", "alpha", false)
	testing.expect_value(t, out, "")
	testing.expect(t, strings.contains(err, "SCENES array not recognised"), err)
}

@(test)
test_registry_data_scene_has_no_import :: proc(t: ^testing.T) {
	out, err := registry_add_scene(REGISTRY_NO_MARKERS, "gamma", true)
	testing.expect_value(t, err, "")
	testing.expect(t, strings.contains(out, "\t{name = \"gamma\"},\n"), "data entry")
	testing.expect(t, !strings.contains(out, `"scenes/gamma"`), "no import for data scene")
}

@(test)
test_scene_add_actor_idempotent_order :: proc(t: ^testing.T) {
	src := "package demo\n\nimport engine \"../../engine\"\n\ndemo_create :: proc(demo: ^engine.Scene) -> bool {\n\tstate := new(State)\n\treturn true\n}\n"
	first, ok := scene_add_actor(src, "demo", "bot", "Bot")
	testing.expect(t, ok, "marker added inside create")
	testing.expect_value(t, strings.count(first, MARK_ACTORS), 1)

	second, ok2 := scene_add_actor(first, "demo", "rock", "Rock")
	testing.expect(t, ok2, "second actor with marker present")
	testing.expect_value(t, strings.count(second, MARK_ACTORS), 1)
	bot_at := strings.index(second, "bot_type :=")
	rock_at := strings.index(second, "rock_type :=")
	marker_at := strings.index(second, MARK_ACTORS)
	testing.expect(t, 0 <= bot_at && bot_at < rock_at && rock_at < marker_at, "actor lines before marker, in order")
	testing.expect(t, strings.contains(second, "\tengine.spawn_typed(&state.world, bot_type, Bot{})"), "spawn line")
}

@(test)
test_scene_add_actor_unrecognised :: proc(t: ^testing.T) {
	_, ok := scene_add_actor("package demo\n", "demo", "bot", "Bot")
	testing.expect(t, !ok, "no create proc: refuse")
}
