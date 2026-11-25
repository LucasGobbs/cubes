package engine
import sdl "vendor:sdl3"
Clock :: struct {
	last_ticks: u64,
	time:      f32,
	delta:     f32,
	fixed_dt:  f32, // > 0: every update advances by exactly this (offline render); 0 = wall clock
}

// Performance counter, not GetTicks: that is whole milliseconds, too coarse for ~6 ms frames.
clock_update :: proc(clock: ^Clock) {
	if clock.fixed_dt > 0 {
		clock.delta = clock.fixed_dt
		clock.time += clock.delta
		return
	}
	now := sdl.GetPerformanceCounter()
	if clock.last_ticks == 0 do clock.last_ticks = now
	clock.delta = f32(f64(now - clock.last_ticks) / f64(sdl.GetPerformanceFrequency()))
	clock.last_ticks = now
	clock.time += clock.delta
}
