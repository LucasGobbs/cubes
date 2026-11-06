package gbbfx
import sdl "vendor:sdl3"
Clock :: struct {
	last_ticks: u64,
	time:      f32,
	delta:     f32,
}

// Performance counter, not GetTicks: that is whole milliseconds, too coarse for ~6 ms frames.
clock_update :: proc(clock: ^Clock) {
	now := sdl.GetPerformanceCounter()
	if clock.last_ticks == 0 do clock.last_ticks = now
	clock.delta = f32(f64(now - clock.last_ticks) / f64(sdl.GetPerformanceFrequency()))
	clock.last_ticks = now
	clock.time += clock.delta
}
