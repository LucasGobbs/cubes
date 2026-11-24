// Scaffolds scenes and actors. Run from the repo root (paths are relative to it):
//   odin run tools/cubes -- new scene <name> [--data] [--dry-run]
//   odin run tools/cubes -- new actor <name> --scene <scene> [--dry-run]
// Names: [a-z][a-z0-9_]*. Existing files are never overwritten; writes roll back on failure.
package main

import "core:fmt"
import "core:os"
import "core:strings"

USAGE :: "usage:\n  cubes new scene <name> [--data] [--dry-run]\n  cubes new actor <name> --scene <scene> [--dry-run]"

Options :: struct {
	data, dry_run: bool,
	scene:         string,
}

File_Edit :: struct {
	path, content: string,
	original:      string, // edits only: content before the edit, for rollback
}

Plan :: struct {
	dirs:    [dynamic]string,
	creates: [dynamic]File_Edit,
	edits:   [dynamic]File_Edit,
}

main :: proc() {
	opts: Options
	positional: [dynamic]string
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--data":
			opts.data = true
		case "--dry-run":
			opts.dry_run = true
		case "--scene":
			if i + 1 >= len(args) do fail("--scene needs a value")
			i += 1
			opts.scene = args[i]
		case:
			append(&positional, args[i])
		}
	}
	if len(positional) != 3 || positional[0] != "new" do fail(USAGE)
	switch positional[1] {
	case "scene":
		scene_command(positional[2], opts)
	case "actor":
		actor_command(positional[2], opts)
	case:
		fail(USAGE)
	}
}

scene_command :: proc(name: string, opts: Options) {
	if opts.scene != "" do fail("--scene only applies to 'new actor'")
	if reason := check_scene_name(name); reason != "" do fail("invalid scene name %q: %s", name, reason)
	dir := join("src/scenes/", name)
	if os.is_dir(dir) || os.is_dir(join("src/", name)) do fail("%q already exists (%s or src/%s)", name, dir, name)

	registry := read_or_fail("src/scene.odin")
	new_registry, err := registry_add_scene(registry, name, opts.data)
	if err != "" do fail("%s", err)

	plan: Plan
	append(&plan.dirs, dir)
	title := capitalize_parts(name, " ")
	if opts.data {
		append(&plan.creates, File_Edit{path = join(dir, "/scene.json"), content = render(SCENE_DATA, "TITLE", title)})
	} else {
		code := render(SCENE_CODE, "NAME", name, "TITLE", title)
		append(&plan.creates, File_Edit{path = join(dir, "/scene.odin"), content = code})
	}
	append(&plan.edits, File_Edit{path = "src/scene.odin", content = new_registry, original = registry})
	execute(&plan, opts.dry_run)
}

actor_command :: proc(name: string, opts: Options) {
	if opts.scene == "" do fail("new actor needs --scene <scene>")
	if opts.data do fail("--data only applies to 'new scene'")
	if reason := check_name(opts.scene); reason != "" do fail("invalid scene name %q: %s", opts.scene, reason)
	if reason := check_actor_name(name, opts.scene); reason != "" do fail("invalid actor name %q: %s", name, reason)
	if os.is_dir(join("src/scenes/", name)) || os.is_dir(join("src/", name)) {
		fail("actor name %q clashes with an existing package directory", name)
	}

	scene_dir := join("src/scenes/", opts.scene)
	scene_path := join(scene_dir, "/scene.odin")
	if !os.exists(scene_path) do fail("scene %q has no scene.odin (data scene or unknown): actors need a code scene", opts.scene)
	actor_path := join(scene_dir, "/", name, ".odin")
	if os.exists(actor_path) do fail("%s already exists", actor_path)

	scene_src := read_or_fail(scene_path)
	type_name := capitalize_parts(name, "_")
	plan: Plan
	code := render(ACTOR_CODE, "SCENE", opts.scene, "TYPE", type_name, "ACTOR", name)
	append(&plan.creates, File_Edit{path = actor_path, content = code})
	new_scene, wired := scene_add_actor(scene_src, opts.scene, name, type_name)
	if wired {
		append(&plan.edits, File_Edit{path = scene_path, content = new_scene, original = scene_src})
	}
	execute(&plan, opts.dry_run)
	if !wired {
		fmt.printfln("%s: structure not recognised, paste these two lines into create before `return true`:", scene_path)
		for line in actor_wiring(name, type_name) do fmt.println(line)
	}
}

// Prints the plan; writes unless dry_run. Added edit lines are shown as "+ line".
execute :: proc(plan: ^Plan, dry_run: bool) {
	for dir in plan.dirs do fmt.printfln("create dir  %s/", dir)
	for file in plan.creates do fmt.printfln("create file %s", file.path)
	for edit in plan.edits {
		fmt.printfln("edit        %s", edit.path)
		for line in added_lines(edit.original, edit.content) do fmt.printfln("    + %s", line)
	}
	if dry_run {
		fmt.println("dry-run: nothing written")
		return
	}
	if !write_plan(plan) do fail("write failed; everything rolled back")
	fmt.println("done")
}

// Lines of new that are not in old, for edits that only insert lines (greedy in-order match).
added_lines :: proc(old, new: string) -> []string {
	old_lines := strings.split(old, "\n", context.temp_allocator)
	new_lines := strings.split(new, "\n", context.temp_allocator)
	added: [dynamic]string
	i := 0
	for line in new_lines {
		if i < len(old_lines) && old_lines[i] == line {
			i += 1
			continue
		}
		append(&added, line)
	}
	return added[:]
}

// Writes dirs, then new files, then edits. On any failure undoes what was done.
write_plan :: proc(plan: ^Plan) -> bool {
	made_dirs: [dynamic]string
	written: [dynamic]string
	restore: [dynamic]File_Edit
	ok := true
	for dir in plan.dirs {
		append(&made_dirs, dir)
		if os.make_directory(dir) != nil {
			fmt.eprintfln("cannot create %s", dir)
			ok = false
			break
		}
	}
	for file in plan.creates do if ok {
		append(&written, file.path)
		if os.write_entire_file_from_string(file.path, file.content) != nil {
			fmt.eprintfln("cannot write %s", file.path)
			ok = false
		}
	}
	for edit in plan.edits do if ok {
		append(&restore, edit)
		if os.write_entire_file_from_string(edit.path, edit.content) != nil {
			fmt.eprintfln("cannot write %s", edit.path)
			ok = false
		}
	}
	if ok do return true

	for path in written do os.remove(path)
	for edit in restore do _ = os.write_entire_file_from_string(edit.path, edit.original)
	#reverse for dir in made_dirs do os.remove(dir)
	return false
}

read_or_fail :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do fail("cannot read %s: run from the repo root", path)
	return string(data)
}

fail :: proc(format: string, args: ..any) -> ! {
	fmt.eprintfln(format, ..args)
	os.exit(1)
}
