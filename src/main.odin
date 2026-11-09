// Entry point: forwards to one scene picked by CLI argument, e.g.
// `./main simple` or `make run ARGS=simple`. Defaults to "benchmark".
// Number keys 1-8 switch scene at runtime (order of SCENES); M toggles MSAA.
// `./main benchmark --bench 10` runs 10 seconds without input, prints stats, exits.
// Fullscreen at desktop size by default (skips the compositor); `--WINDOWED` opts out.
package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import gbbfx "gbbfx"
import scenekit "scenekit"
import glove "glove"
import sdl "vendor:sdl3"

quit_action: glove.Button_Action
msaa_action: glove.Button_Action
switch_actions: [len(SCENES)]glove.Button_Action
current_scene: int
// Input state before the scene registered its own actions; switching rewinds
// to it so scenes do not accumulate dead actions and bindings.
scene_input_mark: glove.Mark
// Benchmark mode (--bench SECONDS); seconds 0 leaves it off.
bench: Bench_Run

main :: proc() {
	context.logger = log.create_console_logger()

	name := "benchmark"
	windowed := false
	for i := 1; i < len(os.args); i += 1 {
		if os.args[i] == "--bench" {
			if i + 1 >= len(os.args) {
				log.errorf("--bench needs a duration in seconds")
				os.exit(1)
			}
			seconds, ok := strconv.parse_f64(os.args[i + 1])
			if !ok || seconds <= 0 {
				log.errorf("--bench: invalid duration %q", os.args[i + 1])
				os.exit(1)
			}
			bench.seconds = seconds
			i += 1
		} else if os.args[i] == "--WINDOWED" {
			windowed = true
		} else {
			name = os.args[i]
		}
	}
	scene, found := scene_lookup(name)
	for new_scene, index in SCENES do if new_scene.name == name do current_scene = index
	if !found {
		log.errorf("unknown scene %q — expected one of:", name)
		for s in SCENES do log.errorf("%s", s.name)
		os.exit(1)
	}

	gfx: gbbfx.Gfx
	// Fullscreen skips the compositor (~2 ms floor, 16 ms spikes); --WINDOWED opts out.
	created := gbbfx.create(&gfx, rawptr(&scene), scene_create, fullscreen = !windowed)
	assert(created)
	// sdl.FlashWindow(gfx.window, .UNTIL_FOCUSED)
	// sdl.ShowSimpleMessageBox({.ERROR}, "Couldn't initialize SDL!", "Error", nil)
	defer gbbfx.gfx_destroy(&gfx, rawptr(&scene), scene_destroy)
	gbbfx.gfx_update(&gfx, rawptr(&scene), scene_tick)
	if bench.seconds > 0 do bench_report(&bench, &gfx, scene.name)
}

scene_create :: proc(gfx: ^gbbfx.Gfx, raw_scene: rawptr) -> bool {
	scene := cast(^scenekit.Scene)raw_scene
	inputs := gbbfx.gfx_input(gfx)
	quit_action = glove.add_button(inputs, "app.quit")
	glove.bind_key(inputs, quit_action, .ESCAPE)
	msaa_action = glove.add_button(inputs, "app.msaa")
	glove.bind_key(inputs, msaa_action, .M)
	for &action, index in switch_actions {
		action = glove.add_button(inputs, SCENES[index].name)
		glove.bind_key(inputs, action, glove.Key(int(glove.Key._1) + index))
	}
	scene_input_mark = glove.system_mark(inputs)
	return scene.create(scene, gfx)
}

scene_tick :: proc(gfx: ^gbbfx.Gfx, delta_time: f32, raw_scene: rawptr) {
	scene := cast(^scenekit.Scene)raw_scene
	inputs := gbbfx.gfx_input(gfx)
	if glove.pressed(inputs, quit_action) {
		gbbfx.gfx_request_quit(gfx)
		return
	}
	if glove.pressed(inputs, msaa_action) {
		renderer := &gfx.renderer
		on := gbbfx.renderer_set_msaa(renderer, !renderer.msaa_enabled)
		log.infof("MSAA %s", on ? "4x" : (renderer.msaa_supported ? "off" : "unsupported"))
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
			"Cubes — %s — %.0f FPS — MSAA %s (M)",
			scene.name,
			1 / delta_time,
			gfx.renderer.msaa_enabled ? "4x" : "off",
			allocator = context.temp_allocator,
		)
		_ = sdl.SetWindowTitle(gfx.window, title)
	}

	if bench.seconds > 0 {
		bench_record(&bench, gfx, delta_time)
		if bench_done(&bench) do gbbfx.gfx_request_quit(gfx)
	}
}

// Tears the running scene down and starts another without restarting the
// device. Runs at the top of a tick, so no frame or pass is open.
scene_switch :: proc(gfx: ^gbbfx.Gfx, scene: ^scenekit.Scene, index: int) {
	log.infof("switching scene: %s -> %s", SCENES[current_scene].name, SCENES[index].name)
	_ = sdl.WaitForGPUIdle(gfx.gpu) // the old scene's buffers may still be in flight
	scene_destroy(gfx, rawptr(scene))
	glove.system_rewind(gbbfx.gfx_input(gfx), scene_input_mark)
	gbbfx.gfx_set_present_mode(gfx, .VSYNC) // the benchmark scene uncaps it

	next, _ := scene_lookup(SCENES[index].name)
	scene^ = next
	current_scene = index
	if !next.create(scene, gfx) {
		log.errorf("scene %q failed to create", SCENES[index].name)
		gbbfx.gfx_request_quit(gfx)
	}
}

scene_destroy :: proc(gfx: ^gbbfx.Gfx, raw_scene: rawptr) {
	scene := cast(^scenekit.Scene)raw_scene
	if scene.state != nil {
		scene.destroy(scene, gfx)
		scene.state = nil
	}
}
