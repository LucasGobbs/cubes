// Benchmark mode, `./main <scene> --bench <seconds>`: runs the scene for that
// long without input, then prints frame, draw-call and CPU stats and exits.
package main

import "core:fmt"
import "core:slice"
import "core:time"
import gbbfx "gbbfx"

// Frames before this are loading and GPU warm-up; they are not sampled.
BENCH_WARMUP :: 4.0

Bench_Run :: struct {
	seconds:    f64, // 0 = off
	elapsed:    f64,
	total:      f64, // wall time including warmup
	frame_ms:   [dynamic]f64,
	draws:      [dynamic]f64,
	triangles:  [dynamic]f64,
	prepare_ms: [dynamic]f64,
	flush_ms:   [dynamic]f64,
	instances:  int, // last frame
}

Bench_Stat :: struct {
	min, avg, p50, p95, p99, max: f64,
}

// Called once per tick after the scene ticked, so renderer counters hold this frame's values.
bench_record :: proc(bench: ^Bench_Run, gfx: ^gbbfx.Gfx, delta_time: f32) {
	if delta_time <= 0 do return // first frame has no previous timestamp
	renderer := &gfx.renderer
	bench.total += f64(delta_time)
	if bench.total < BENCH_WARMUP do return
	bench.elapsed += f64(delta_time)
	append(&bench.frame_ms, f64(delta_time) * 1000)
	append(&bench.draws, f64(renderer.draw_calls))
	append(&bench.triangles, f64(renderer.triangles))
	append(&bench.prepare_ms, time.duration_milliseconds(renderer.prepare_time))
	append(&bench.flush_ms, time.duration_milliseconds(renderer.flush_time))
	bench.instances = len(renderer.instance_transforms)
}

bench_done :: proc(bench: ^Bench_Run) -> bool {
	return bench.elapsed >= bench.seconds
}

// Nearest-rank percentile on a sorted slice.
bench_percentile :: proc(sorted: []f64, p: f64) -> f64 {
	return sorted[int(p * f64(len(sorted) - 1))]
}

bench_stat :: proc(values: []f64) -> Bench_Stat {
	if len(values) == 0 do return {}
	sorted := slice.clone(values, context.temp_allocator)
	slice.sort(sorted)
	sum: f64
	for v in sorted do sum += v
	return {
		min = sorted[0],
		avg = sum / f64(len(sorted)),
		p50 = bench_percentile(sorted, 0.50),
		p95 = bench_percentile(sorted, 0.95),
		p99 = bench_percentile(sorted, 0.99),
		max = sorted[len(sorted) - 1],
	}
}

bench_report :: proc(bench: ^Bench_Run, gfx: ^gbbfx.Gfx, scene_name: string) {
	frames := len(bench.frame_ms)
	if frames == 0 {
		fmt.printf("benchmark: no frames rendered\n")
		return
	}
	frame := bench_stat(bench.frame_ms[:])
	draws := bench_stat(bench.draws[:])
	prepare := bench_stat(bench.prepare_ms[:])
	flush := bench_stat(bench.flush_ms[:])
	triangles := bench_stat(bench.triangles[:])
	fmt.printf(
		"benchmark  scene=%s  window=%dx%d  msaa=%s  duration=%.2fs  frames=%d\n",
		scene_name,
		gfx.window_size.x,
		gfx.window_size.y,
		gfx.renderer.msaa_enabled ? "4x" : "off",
		bench.elapsed,
		frames,
	)
	fmt.printf(
		"  fps          avg %.1f   min %.1f   max %.1f   p99 low %.1f\n",
		f64(frames) / bench.elapsed,
		1000 / frame.max,
		1000 / frame.min,
		1000 / frame.p99,
	)
	fmt.printf(
		"  frame ms     avg %.2f   p50 %.2f   p95 %.2f   p99 %.2f   max %.2f\n",
		frame.avg,
		frame.p50,
		frame.p95,
		frame.p99,
		frame.max,
	)
	fmt.printf("  draw calls   avg %.1f   min %.0f   max %.0f\n", draws.avg, draws.min, draws.max)
	fmt.printf("  triangles    avg %.0f\n", triangles.avg)
	fmt.printf("  instances    %d (last frame)\n", bench.instances)
	fmt.printf(
		"  cpu prepare  avg %.3f   p95 %.3f   max %.3f ms\n",
		prepare.avg,
		prepare.p95,
		prepare.max,
	)
	fmt.printf("  cpu flush    avg %.3f   p95 %.3f   max %.3f ms\n", flush.avg, flush.p95, flush.max)
}
