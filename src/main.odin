// Entry point: forwards to one scene picked by CLI argument, e.g.
// `./main simple` or `make run ARGS=simple`. Defaults to "benchmark".
package main

import gbbfx "gbbfx"
import glove "glove"
import "core:fmt"
import "core:log"
import "core:os"
import sdl "vendor:sdl3"

quit_action: glove.Button_Action

main :: proc() {
	context.logger = log.create_console_logger()

	name := "benchmark"
	if len(os.args) > 1 do name = os.args[1]
	scene, found := scene_lookup(name)
	if !found {
		log.errorf("unknown scene %q — expected one of: %v", name, SCENE_NAMES)
		os.exit(1)
	}

	gfx: gbbfx.Gfx
	created := gbbfx.create(&gfx, rawptr(&scene), scene_create)
	assert(created)
	defer gbbfx.gfx_destroy(&gfx, rawptr(&scene), scene_destroy)
	gbbfx.gfx_update(&gfx, rawptr(&scene), scene_tick)
}

scene_create :: proc(gfx: ^gbbfx.Gfx, raw_scene: rawptr) -> bool {
	scene := cast(^Scene)raw_scene
	inputs := gbbfx.gfx_input(gfx)
	quit_action = glove.add_button(inputs, "app.quit")
	glove.bind_key(inputs, quit_action, .ESCAPE)
	return scene.create(scene, gfx)
}

scene_tick :: proc(gfx: ^gbbfx.Gfx, delta_time: f32, raw_scene: rawptr) {
	scene := cast(^Scene)raw_scene
	inputs := gbbfx.gfx_input(gfx)
	if glove.pressed(inputs, quit_action) {
		gbbfx.gfx_request_quit(gfx)
		return
	}
	scene.tick(scene, gfx, delta_time)

	scene.fps_timer += delta_time
	if scene.fps_timer >= 0.5 {
		scene.fps_timer = 0
		title := fmt.caprintf(
			"Cubes — %s — %.0f FPS",
			scene.name,
			1 / delta_time,
			allocator = context.temp_allocator,
		)
		_ = sdl.SetWindowTitle(gfx.window, title)
	}
}

scene_destroy :: proc(gfx: ^gbbfx.Gfx, raw_scene: rawptr) {
	scene := cast(^Scene)raw_scene
	if scene.state != nil {
		scene.destroy(scene, gfx)
		scene.state = nil
	}
}
