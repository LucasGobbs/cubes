// Entry point: forwards to one scene picked by CLI argument, e.g.
// `./main skinned` or `make run ARGS=skinned`. Defaults to "benchmark".
// Number keys 1-9 switch scene at runtime (order of SCENES); M toggles MSAA.
// `./main benchmark --bench 10` runs 10 seconds without input, prints stats, exits.
// `--display N` opens the window on monitor N (1-based; primary if there is no such monitor).
// `--record ex,ey,ez,tx,ty,tz` arcs a camera around a target for 10 s then quits (src/record.odin).
// `--render-video out.mp4 [--fps N] [--seconds S] [--video-size WxH]` renders offline at fixed 1/fps steps into an mp4 (src/video.odin).
// Fullscreen at desktop size by default (skips the compositor); `--WINDOWED` opts out.
package main

import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "engine/gfx"
import engine "engine"

// Benchmark mode (--bench SECONDS); seconds 0 leaves it off.
bench: Bench_Run

main :: proc() {
	context.logger = log.create_console_logger()

	name := "benchmark"
	windowed := false
	display := 0
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
		} else if os.args[i] == "--record" {
			parts: [6]f32
			ok := i + 1 < len(os.args)
			if ok {
				fields := strings.split(os.args[i + 1], ",", context.temp_allocator)
				ok = len(fields) == 6 || (len(fields) == 7 && fields[6] == "fly")
				record.fly = len(fields) == 7
				for f, k in fields[:min(len(fields), 6)] do if ok && k < 6 do parts[k], ok = strconv.parse_f32(f)
			}
			if !ok {
				log.errorf("--record needs ex,ey,ez,tx,ty,tz (camera position and look-at target)")
				os.exit(1)
			}
			record.on = true
			record.eye, record.target = {parts[0], parts[1], parts[2]}, {parts[3], parts[4], parts[5]}
			i += 1
		} else if os.args[i] == "--display" {
			n, ok := 0, false
			if i + 1 < len(os.args) do n, ok = strconv.parse_int(os.args[i + 1])
			if !ok || n < 1 {
				log.errorf("--display needs a monitor number (1 = first)")
				os.exit(1)
			}
			display = n
			i += 1
		} else if os.args[i] == "--WINDOWED" {
			windowed = true
		} else if os.args[i] == "--render-video" {
			if i + 1 >= len(os.args) {
				log.errorf("--render-video needs an output path")
				os.exit(1)
			}
			video.path = os.args[i + 1]
			i += 1
		} else if os.args[i] == "--fps" {
			n, ok := 0, false
			if i + 1 < len(os.args) do n, ok = strconv.parse_int(os.args[i + 1])
			if !ok || n < 1 {
				log.errorf("--fps needs a positive integer")
				os.exit(1)
			}
			video.fps = n
			i += 1
		} else if os.args[i] == "--seconds" {
			s, ok := 0.0, false
			if i + 1 < len(os.args) do s, ok = strconv.parse_f64(os.args[i + 1])
			if !ok || s <= 0 {
				log.errorf("--seconds needs a positive duration")
				os.exit(1)
			}
			video.seconds = s
			i += 1
		} else if os.args[i] == "--video-size" {
			w, h, ok := 0, 0, false
			if i + 1 < len(os.args) {
				dims := strings.split(os.args[i + 1], "x", context.temp_allocator)
				ok = len(dims) == 2
				if ok {
					w, ok = strconv.parse_int(dims[0])
				}
				if ok {
					h, ok = strconv.parse_int(dims[1])
				}
			}
			if !ok || w < 1 || h < 1 {
				log.errorf("--video-size needs WxH, e.g. 1920x1080")
				os.exit(1)
			}
			video.w, video.h = w, h
			i += 1
		} else if os.args[i] == "--indirect" {
			gfx.indirect_draws = true
		} else {
			name = os.args[i]
		}
	}

	video.total = int(f64(video.fps) * video.seconds)
	fixed_dt := f32(0)
	if video.path != "" {
		video_begin()
		fixed_dt = 1 / f32(video.fps)
	}

	engine.run(
		engine.Config {
			width = video.w,
			height = video.h,
			fullscreen = !windowed && video.path == "",
			display = display,
			scenes = SCENES[:],
			start = name,
			after_frame = frame_hook,
			fixed_dt = fixed_dt,
			readback = video.path != "",
			before_exit = video_exit_hook,
		},
	)
}
