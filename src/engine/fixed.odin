package engine

// Fixed-timestep accumulator. Returns how many steps to run this frame (capped
// at max_steps; excess time is dropped so a long stall cannot spiral) and the
// leftover fraction of a step (0..1) for render interpolation.
fixed_steps :: proc(accumulator: ^f32, dt, step: f32, max_steps: int) -> (steps: int, blend: f32) {
	accumulator^ += dt
	steps = min(int(accumulator^ / step), max_steps)
	accumulator^ = max(accumulator^ - f32(steps) * step, 0) // rounding can leave a tiny negative
	if steps == max_steps && accumulator^ >= step do accumulator^ = 0
	return steps, accumulator^ / step
}
