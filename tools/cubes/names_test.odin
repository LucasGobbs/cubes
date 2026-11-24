package main

import "core:testing"

@(test)
test_check_name :: proc(t: ^testing.T) {
	cases := [?]struct {
		name:  string,
		valid: bool,
	} {
		{"bot", true},
		{"cli_smoke", true},
		{"a", true},
		{"sea2_ship", true},
		{"", false},
		{"Bot", false},
		{"_bot", false},
		{"2bot", false},
		{"bot-ship", false},
		{"bot.ship", false},
		{"bot ship", false},
		{"../x", false},
		{"for", false},
		{"struct", false},
		{"proc", false},
		{"import", false},
	}
	for c in cases {
		reason := check_name(c.name)
		testing.expectf(t, (reason == "") == c.valid, "check_name(%q) = %q, want valid=%v", c.name, reason, c.valid)
	}
}

@(test)
test_check_scene_name :: proc(t: ^testing.T) {
	testing.expect(t, check_scene_name("main") != "", "main clashes with package main")
	testing.expect(t, check_scene_name("engine") != "", "engine clashes with the engine import")
	testing.expect_value(t, check_scene_name("cli_smoke"), "")
}

@(test)
test_check_actor_name :: proc(t: ^testing.T) {
	testing.expect(t, check_actor_name("state", "demo") != "", "state clashes with State")
	testing.expect(t, check_actor_name("demo", "demo") != "", "actor equal to scene clashes with procs")
	testing.expect(t, check_actor_name("bad-name", "demo") != "", "invalid chars rejected")
	testing.expect_value(t, check_actor_name("bot", "demo"), "")
}

@(test)
test_capitalize_parts :: proc(t: ^testing.T) {
	testing.expect_value(t, capitalize_parts("cli_smoke", " "), "Cli Smoke")
	testing.expect_value(t, capitalize_parts("sea_ship", "_"), "Sea_Ship")
	testing.expect_value(t, capitalize_parts("bot", "_"), "Bot")
	testing.expect_value(t, capitalize_parts("bot_2d", "_"), "Bot_2d")
}
