package gbbfx
import sdl "vendor:sdl3"
Clock :: struct {
	last_time: f32,
	time:      f32,
	delta:     f32,
}

clock_update :: proc(clock: ^Clock) {
	current_time := f32(sdl.GetTicks()) / 1000
	if clock.last_time == 0 do clock.last_time = current_time
	clock.delta = current_time - clock.last_time
	clock.last_time = current_time
	clock.time = current_time
}
