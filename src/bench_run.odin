// Baseline (phase 0, 5 s, 1512x982, msaa 4x), cpu ms avg:
//   forest_instanced: frame 5.8-6.4 (p95 16.4-16.7), draws 119, instances 11168, prepare 2.0, extract 0.95-0.98, shadow 0.09, flush 0.08
//   benchmark:        frame 5.1-8.3 (p95 9.4-13.4), draws 36, instances 2127, prepare 0.48-0.60, extract 0 (not via draws extract), shadow 0.03, flush 0.03
// Benchmark mode, `./main <scene> --bench <seconds>`: runs the scene for that
// long without input, then prints frame, draw-call and CPU stats and exits.
package main

import "core:fmt"
import "core:slice"
import "core:time"
import engine "engine"
import gfx "engine/gfx"

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
	extract_ms: [dynamic]f64,
	shadow_ms:  [dynamic]f64,
	flush_ms:   [dynamic]f64,
	script_ms:  [dynamic]f64, // Lua tick + fixed + gc per frame; empty without a Lua host
	instances:  int, // last frame
}

Bench_Stat :: struct {
	min, avg, p50, p95, p99, max: f64,
}

// Called once per tick after the scene ticked, so renderer counters hold this frame's values.
bench_record :: proc(bench: ^Bench_Run, gfx_ctx: ^gfx.Device, delta_time: f32) {
	script_ms, has_script := engine.script_take_frame_ms() // read every frame so warmup time is dropped
	if delta_time <= 0 do return // first frame has no previous timestamp
	renderer := &gfx_ctx.renderer
	bench.total += f64(delta_time)
	if bench.total < BENCH_WARMUP do return
	bench.elapsed += f64(delta_time)
	append(&bench.frame_ms, f64(delta_time) * 1000)
	append(&bench.draws, f64(renderer.draw_calls))
	append(&bench.triangles, f64(renderer.triangles))
	append(&bench.prepare_ms, time.duration_milliseconds(renderer.prepare_time))
	append(&bench.flush_ms, time.duration_milliseconds(renderer.flush_time))
	append(&bench.extract_ms, time.duration_milliseconds(renderer.extract_time))
	append(&bench.shadow_ms, time.duration_milliseconds(renderer.shadow_time))
	if has_script do append(&bench.script_ms, f64(script_ms))
	bench.instances = renderer.instance_count
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

bench_report :: proc(bench: ^Bench_Run, gfx_ctx: ^gfx.Device, scene_name: string) {
	frames := len(bench.frame_ms)
	if frames == 0 {
		fmt.printf("benchmark: no frames rendered\n")
		return
	}
	frame := bench_stat(bench.frame_ms[:])
	draws := bench_stat(bench.draws[:])
	prepare := bench_stat(bench.prepare_ms[:])
	flush := bench_stat(bench.flush_ms[:])
	extract := bench_stat(bench.extract_ms[:])
	shadow := bench_stat(bench.shadow_ms[:])
	triangles := bench_stat(bench.triangles[:])
	fmt.printf(
		"benchmark  scene=%s  window=%dx%d  msaa=%s  duration=%.2fs  frames=%d\n",
		scene_name,
		gfx_ctx.window_size.x,
		gfx_ctx.window_size.y,
		gfx_ctx.renderer.msaa_enabled ? "4x" : "off",
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
	fmt.printf("  cpu extract  avg %.3f   p95 %.3f   max %.3f ms\n", extract.avg, extract.p95, extract.max)
	fmt.printf("  cpu shadow   avg %.3f   p95 %.3f   max %.3f ms\n", shadow.avg, shadow.p95, shadow.max)
	if len(bench.script_ms) > 0 {
		script := bench_stat(bench.script_ms[:])
		fmt.printf("  script ms    avg %.3f   p95 %.3f   max %.3f\n", script.avg, script.p95, script.max)
	} else {
		fmt.printf("  script ms    n/a (no Lua host; frame ms is the total)\n")
	}
}

// Config.after_frame: records one frame and stops the run once the duration is met.
bench_after_frame :: proc(ctx: ^engine.Context, scene_name: string, delta_time: f32, user: rawptr) {
	if bench.seconds <= 0 do return
	bench_record(&bench, &ctx.gfx, delta_time)
	if bench_done(&bench) do engine.request_quit(ctx)
}

// Config.before_exit: prints the report after the loop, before the scene is torn down.
bench_before_exit :: proc(ctx: ^engine.Context, scene_name: string, user: rawptr) {
	if bench.seconds > 0 do bench_report(&bench, &ctx.gfx, scene_name)
}
