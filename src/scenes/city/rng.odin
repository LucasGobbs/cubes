// xorshift32 for CPU generation: deterministic from the seed, never stuck at zero.
package city

Rng :: struct {
	state: u32,
}

rng_seed :: proc(seed: u32) -> Rng {
	return {state = seed if seed != 0 else 1}
}

rng_u32 :: proc(r: ^Rng) -> u32 {
	s := r.state
	s ~= s << 13
	s ~= s >> 17
	s ~= s << 5
	r.state = s
	return s
}

// [0, 1)
rng_f32 :: proc(r: ^Rng) -> f32 {
	return f32(rng_u32(r) >> 8) * (1.0 / 16777216.0)
}

rng_range :: proc(r: ^Rng, lo, hi: f32) -> f32 {
	return lo + (hi - lo) * rng_f32(r)
}

// Inclusive on both ends.
rng_int :: proc(r: ^Rng, lo, hi: int) -> int {
	return lo + int(rng_u32(r) % u32(hi - lo + 1))
}
