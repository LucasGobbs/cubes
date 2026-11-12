// Entry point: forwards to one scene picked by CLI argument, e.g.
// `./main simple` or `make run ARGS=simple`. Defaults to "benchmark".
// Number keys 1-9 switch scene at runtime (order of SCENES); M toggles MSAA.
// `./main benchmark --bench 10` runs 10 seconds without input, prints stats, exits.
// Fullscreen at desktop size by default (skips the compositor); `--WINDOWED` opts out.
package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import engine "engine"
import gfx "engine/gfx"
import input "engine/input"
import sdl "vendor:sdl3"

quit_action: input.Button_Action
msaa_action: input.Button_Action
switch_actions: [len(SCENES)]input.Button_Action
current_scene: int
// Input state before the scene registered its own actions; switching rewinds
// to it so scenes do not accumulate dead actions and bindings.
scene_input_mark: input.Mark
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

	dev: gfx.Device
	// Fullscreen skips the compositor (~2 ms floor, 16 ms spikes); --WINDOWED opts out.
	created := gfx.create(&dev, rawptr(&scene), scene_create, fullscreen = !windowed)
	assert(created)
	// sdl.FlashWindow(dev.window, .UNTIL_FOCUSED)
	// sdl.ShowSimpleMessageBox({.ERROR}, "Couldn't initialize SDL!", "Error", nil)
	defer gfx.gfx_destroy(&dev, rawptr(&scene), scene_destroy)
	defer {
		transition_destroy(&dev)
		stats_destroy(&dev) // runs first (LIFO), while the device is alive
	}
	gfx.gfx_update(&dev, rawptr(&scene), scene_tick)
	if bench.seconds > 0 do bench_report(&bench, &dev, scene.name)
}

scene_create :: proc(dev: ^gfx.Device, raw_scene: rawptr) -> bool {
	scene := cast(^engine.Scene)raw_scene
	inputs := gfx.gfx_input(dev)
	quit_action = input.add_button(inputs, "app.quit")
	input.bind_key(inputs, quit_action, .ESCAPE)
	msaa_action = input.add_button(inputs, "app.msaa")
	input.bind_key(inputs, msaa_action, .M)
	for &action, index in switch_actions {
		action = input.add_button(inputs, SCENES[index].name)
		input.bind_key(inputs, action, input.Key(int(input.Key._1) + index))
	}
	transition_create(dev)
	stats_create(dev)
	scene_input_mark = input.system_mark(inputs)
	return scene.create(scene, dev)
}

scene_tick :: proc(dev: ^gfx.Device, delta_time: f32, raw_scene: rawptr) {
	scene := cast(^engine.Scene)raw_scene
	inputs := gfx.gfx_input(dev)
	if input.pressed(inputs, quit_action) {
		gfx.gfx_request_quit(dev)
		return
	}
	if input.pressed(inputs, msaa_action) {
		renderer := &dev.renderer
		on := gfx.renderer_set_msaa(renderer, !renderer.msaa_enabled)
		log.infof("MSAA %s", on ? "4x" : (renderer.msaa_supported ? "off" : "unsupported"))
	}
	for action, index in switch_actions {
		if index != current_scene && input.pressed(inputs, action) {
			engine.change_scene(SCENES[index].name, .Fade, 0.5)
		}
	}
	if transition_tick(dev, scene, delta_time) do return
	stats_tick(dev, delta_time, scene.name)
	scene.tick(scene, dev, delta_time)

	scene.fps_timer += delta_time
	if scene.fps_timer >= 0.5 {
		scene.fps_timer = 0
		title := fmt.caprintf(
			"Cubes — %s — %.0f FPS — MSAA %s (M)",
			scene.name,
			1 / delta_time,
			dev.renderer.msaa_enabled ? "4x" : "off",
			allocator = context.temp_allocator,
		)
		_ = sdl.SetWindowTitle(dev.window, title)
	}

	if bench.seconds > 0 {
		bench_record(&bench, dev, delta_time)
		if bench_done(&bench) do gfx.gfx_request_quit(dev)
	}
}

// Tears the running scene down and starts another without restarting the
// device. Runs at the top of a tick, so no frame or pass is open.
scene_switch :: proc(dev: ^gfx.Device, scene: ^engine.Scene, index: int) {
	log.infof("switching scene: %s -> %s", SCENES[current_scene].name, SCENES[index].name)
	_ = sdl.WaitForGPUIdle(dev.gpu) // the old scene's buffers may still be in flight
	scene_destroy(dev, rawptr(scene))
	input.system_rewind(gfx.gfx_input(dev), scene_input_mark)
	gfx.gfx_set_present_mode(dev, .IMMEDIATE)

	next, _ := scene_lookup(SCENES[index].name)
	scene^ = next
	current_scene = index
	if !next.create(scene, dev) {
		log.errorf("scene %q failed to create", SCENES[index].name)
		gfx.gfx_request_quit(dev)
	}
}

scene_destroy :: proc(dev: ^gfx.Device, raw_scene: rawptr) {
	scene := cast(^engine.Scene)raw_scene
	if scene.state != nil {
		scene.destroy(scene, dev)
		scene.state = nil
	}
}
