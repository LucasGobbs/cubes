// Entry point: forwards to one scene picked by CLI argument, e.g.
// `./main simple` or `make run ARGS=simple`. Defaults to "benchmark".
// Number keys 1-4 switch scene at runtime (order of SCENE_NAMES).
package main

import "core:fmt"
import "core:log"
import "core:os"
import gbbfx "gbbfx"
import glove "glove"
import sdl "vendor:sdl3"

quit_action: glove.Button_Action
switch_actions: [len(SCENE_NAMES)]glove.Button_Action
current_scene: int
// Input state before the scene registered its own actions; switching rewinds
// to it so scenes do not accumulate dead actions and bindings.
scene_input_mark: glove.Mark

main :: proc() {
	context.logger = log.create_console_logger()

	name := "benchmark"
	if len(os.args) > 1 do name = os.args[1]
	scene, found := scene_lookup(name)
	for scene_name, index in SCENE_NAMES do if scene_name == name do current_scene = index
	if !found {
		log.errorf("unknown scene %q — expected one of: %v", name, SCENE_NAMES)
		os.exit(1)
	}

	gfx: gbbfx.Gfx
	created := gbbfx.create(&gfx, rawptr(&scene), scene_create)
	assert(created)
	// sdl.FlashWindow(gfx.window, .UNTIL_FOCUSED)
	// sdl.ShowSimpleMessageBox({.ERROR}, "Couldn't initialize SDL!", "Error", nil)
	defer gbbfx.gfx_destroy(&gfx, rawptr(&scene), scene_destroy)
	gbbfx.gfx_update(&gfx, rawptr(&scene), scene_tick)
}

scene_create :: proc(gfx: ^gbbfx.Gfx, raw_scene: rawptr) -> bool {
	scene := cast(^Scene)raw_scene
	inputs := gbbfx.gfx_input(gfx)
	quit_action = glove.add_button(inputs, "app.quit")
	glove.bind_key(inputs, quit_action, .ESCAPE)
	for &action, index in switch_actions {
		action = glove.add_button(inputs, SCENE_NAMES[index])
		glove.bind_key(inputs, action, glove.Key(int(glove.Key._1) + index))
	}
	scene_input_mark = glove.system_mark(inputs)
	return scene.create(scene, gfx)
}

scene_tick :: proc(gfx: ^gbbfx.Gfx, delta_time: f32, raw_scene: rawptr) {
	scene := cast(^Scene)raw_scene
	inputs := gbbfx.gfx_input(gfx)
	if glove.pressed(inputs, quit_action) {
		gbbfx.gfx_request_quit(gfx)
		return
	}
	for action, index in switch_actions {
		if index != current_scene && glove.pressed(inputs, action) {
			scene_switch(gfx, scene, index)
			return
		}
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

// Tears the running scene down and starts another without restarting the
// device. Runs at the top of a tick, so no frame or pass is open.
scene_switch :: proc(gfx: ^gbbfx.Gfx, scene: ^Scene, index: int) {
	log.infof("switching scene: %s -> %s", SCENE_NAMES[current_scene], SCENE_NAMES[index])
	_ = sdl.WaitForGPUIdle(gfx.gpu) // the old scene's buffers may still be in flight
	scene_destroy(gfx, rawptr(scene))
	glove.system_rewind(gbbfx.gfx_input(gfx), scene_input_mark)
	gbbfx.gfx_set_present_mode(gfx, .VSYNC) // the benchmark scene uncaps it

	next, _ := scene_lookup(SCENE_NAMES[index])
	scene^ = next
	current_scene = index
	if !next.create(scene, gfx) {
		log.errorf("scene %q failed to create", SCENE_NAMES[index])
		gbbfx.gfx_request_quit(gfx)
	}
}

scene_destroy :: proc(gfx: ^gbbfx.Gfx, raw_scene: rawptr) {
	scene := cast(^Scene)raw_scene
	if scene.state != nil {
		scene.destroy(scene, gfx)
		scene.state = nil
	}
}
