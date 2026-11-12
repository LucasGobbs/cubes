// Entry point: forwards to one scene picked by CLI argument, e.g.
// `./main simple` or `make run ARGS=simple`. Defaults to "benchmark".
// Number keys 1-9 switch scene at runtime (order of SCENES); M toggles MSAA.
// `./main benchmark --bench 10` runs 10 seconds without input, prints stats, exits.
// Fullscreen at desktop size by default (skips the compositor); `--WINDOWED` opts out.
package main

import "core:log"
import "core:os"
import "core:strconv"
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
		} else if os.args[i] == "--WINDOWED" {
			windowed = true
		} else {
			name = os.args[i]
		}
	}

	engine.run(
		engine.Config {
			fullscreen = !windowed,
			scenes = SCENES[:],
			start = name,
			after_frame = bench_after_frame,
			before_exit = bench_before_exit,
		},
	)
}
