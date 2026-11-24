// Name rules for scenes and actors, and the identifiers derived from them.
package main

import "core:strings"

// Odin keywords and predeclared literals: a package or identifier may not use them.
ODIN_KEYWORDS :: [?]string {
	"asm",
	"auto_cast",
	"bit_field",
	"bit_set",
	"break",
	"case",
	"cast",
	"context",
	"continue",
	"defer",
	"distinct",
	"do",
	"dynamic",
	"else",
	"enum",
	"fallthrough",
	"false",
	"for",
	"foreign",
	"if",
	"import",
	"in",
	"inline",
	"map",
	"matrix",
	"nil",
	"no_inline",
	"not_in",
	"or_else",
	"or_return",
	"package",
	"proc",
	"return",
	"struct",
	"switch",
	"transmute",
	"true",
	"typeid",
	"union",
	"using",
	"when",
	"where",
}

// "" when name matches [a-z][a-z0-9_]* and is not an Odin keyword; otherwise the reason.
check_name :: proc(name: string) -> string {
	if name == "" do return "name is empty"
	if name[0] < 'a' || name[0] > 'z' do return "name must start with a-z"
	for c in name {
		if (c < 'a' || c > 'z') && (c < '0' || c > '9') && c != '_' {
			return "name may only contain a-z, 0-9 and _"
		}
	}
	for keyword in ODIN_KEYWORDS do if keyword == name do return "name is an Odin keyword"
	return ""
}

// Scene packages are imported by name into src/scene.odin next to engine.
check_scene_name :: proc(name: string) -> string {
	if reason := check_name(name); reason != "" do return reason
	if name == "main" || name == "engine" do return "name clashes with package main or engine"
	return ""
}

// Actor identifiers share the scene package with the scene's own procs and State type.
check_actor_name :: proc(actor, scene: string) -> string {
	if reason := check_name(actor); reason != "" do return reason
	if actor == scene do return "actor name equals the scene name (procs would clash)"
	if actor == "state" do return "name 'state' clashes with the scene's State type"
	return ""
}

// "cli_smoke" -> "Cli Smoke" (sep " ") or "Cli_Smoke" (sep "_"): each segment capitalised.
capitalize_parts :: proc(name, sep: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for part, i in strings.split(name, "_", context.temp_allocator) {
		if i > 0 do strings.write_string(&b, sep)
		if part == "" do continue
		first := part[0]
		if first >= 'a' && first <= 'z' do first -= 'a' - 'A'
		strings.write_byte(&b, first)
		strings.write_string(&b, part[1:])
	}
	return strings.to_string(b)
}
