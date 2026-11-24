// Entry point: forwards to one scene picked by CLI argument, e.g.
// `./main skinned` or `make run ARGS=skinned`. Defaults to "benchmark".
// Number keys 1-9 switch scene at runtime (order of SCENES); M toggles MSAA.
// `./main benchmark --bench 10` runs 10 seconds without input, prints stats, exits.
// `--record ex,ey,ez,tx,ty,tz` arcs a camera around a target for 10 s then quits (src/record.odin).
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
				ok = len(fields) == 6
				for f, k in fields do if ok && k < 6 do parts[k], ok = strconv.parse_f32(f)
			}
			if !ok {
				log.errorf("--record needs ex,ey,ez,tx,ty,tz (camera position and look-at target)")
				os.exit(1)
			}
			record.on = true
			record.eye, record.target = {parts[0], parts[1], parts[2]}, {parts[3], parts[4], parts[5]}
			i += 1
		} else if os.args[i] == "--WINDOWED" {
			windowed = true
		} else if os.args[i] == "--indirect" {
			gfx.indirect_draws = true
		} else {
			name = os.args[i]
		}
	}

	engine.run(
		engine.Config {
			width = 1280,
			height = 720,
			fullscreen = !windowed,
			scenes = SCENES[:],
			start = name,
			after_frame = frame_hook,
			before_exit = bench_before_exit,
		},
	)
}
