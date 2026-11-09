// CPU mirror of shaders/sea.slang surface height. Boats read this so they sit
// on the same waves the sea mesh is displaced by.
// wave_height in shaders/sea.slang (vertex path, fine=false). Keep in sync.
package benchmark

import "core:math"
import "core:math/linalg"

SEA_WAVE_COUNT :: 3 // sine waves that displace the mesh; shorter ones only shade

sea_mod289_3 :: proc(x: [3]f32) -> [3]f32 {
	return x - linalg.floor(x * (1.0 / 289.0)) * 289.0
}

sea_mod289_2 :: proc(x: [2]f32) -> [2]f32 {
	return x - linalg.floor(x * (1.0 / 289.0)) * 289.0
}

sea_permute3 :: proc(x: [3]f32) -> [3]f32 {
	return sea_mod289_3((x * 34.0 + 1.0) * x)
}

// Gustavson 2D simplex, values in about [-1, 1].
sea_simplex2 :: proc(v: [2]f32) -> f32 {
	C := [4]f32{0.211324865405187, 0.366025403784439, -0.577350269189626, 0.024390243902439}
	i := linalg.floor(v + linalg.dot(v, [2]f32{C.y, C.y}))
	x0 := v - i + linalg.dot(i, [2]f32{C.x, C.x})
	i1: [2]f32 = x0.x > x0.y ? {1, 0} : {0, 1}
	x12 := [4]f32{x0.x + C.x, x0.y + C.x, x0.x + C.z, x0.y + C.z}
	x12.xy -= i1
	i = sea_mod289_2(i)
	ya := sea_permute3({i.y, i.y + i1.y, i.y + 1})
	pp := sea_permute3(ya + i.x + [3]f32{0, i1.x, 1})
	m := [3]f32 {
		max(0.5 - linalg.dot(x0, x0), 0),
		max(0.5 - linalg.dot(x12.xy, x12.xy), 0),
		max(0.5 - linalg.dot(x12.zw, x12.zw), 0),
	}
	m = m * m
	m = m * m
	fr := pp * C.w
	x := 2.0 * (fr - linalg.floor(fr)) - 1.0
	h := [3]f32{abs(x.x), abs(x.y), abs(x.z)} - 0.5
	ox := linalg.floor(x + 0.5)
	a0 := x - ox
	m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h)
	g := [3]f32 {
		a0.x * x0.x + h.x * x0.y,
		a0.y * x12.x + h.y * x12.y,
		a0.z * x12.z + h.z * x12.w,
	}
	return 130.0 * linalg.dot(m, g)
}

// x = height sample, yz = forward-difference slope; mirrors `swell` in sea.slang.
sea_swell :: proc(p: [2]f32, freq, speed, time: f32) -> [3]f32 {
	q := p * freq + [2]f32{time * speed, 0}
	s := sea_simplex2(q)
	return {s, sea_simplex2(q + [2]f32{freq, 0}) - s, sea_simplex2(q + [2]f32{0, freq}) - s}
}

sea_smoothstep :: proc(e0, e1, x: f32) -> f32 {
	t := clamp((x - e0) / (e1 - e0), 0, 1)
	return t * t * (3 - 2 * t)
}

// Surface height and horizontal gradient at p. dist is camera distance, which
// fades each wave. Only the sine waves and broad swell, the part the mesh
// displaces; the fine swell is shading-only (see wave_height in sea.slang).
sea_surface_height :: proc(p: [2]f32, time, dist: f32) -> (h: f32, grad: [2]f32) {
	wavelength := f32(70)
	angle := f32(0.3)
	for _ in 0 ..< SEA_WAVE_COUNT {
		k := 2 * math.PI / wavelength
		omega := math.sqrt(f32(9.81) * k)
		amplitude := f32(0.06) / k
		dir := [2]f32{math.cos(angle), math.sin(angle)}
		fade := 1 - sea_smoothstep(wavelength * 80, wavelength * 160, dist)
		phase := linalg.dot(dir, p) * k - omega * time
		h += amplitude * math.sin(phase) * fade
		grad += amplitude * k * math.cos(phase) * dir * fade
		wavelength *= 0.68
		angle += 2.39996
	}
	nf := 1 - sea_smoothstep(300, 1500, dist)
	broad := sea_swell(p, 0.008, 0.01, time)
	h += nf * 3.0 * broad.x
	grad += nf * 3.0 * broad.yz
	return h, grad
}
