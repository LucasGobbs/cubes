package forest

import "core:math"
import "core:math/linalg"
import gbbfx "../../gbbfx"

WORLD_HALF :: 256.0
CHUNK_SIZE :: 16.0
CHUNKS_PER_SIDE :: 32

// 1 m grid: 17x17 verts, 16x16 cells, 289 verts / 1536 indices per chunk (< 65535, u16-safe).
TERRAIN_VERTS_PER_SIDE :: 17
TERRAIN_CELLS_PER_SIDE :: 16

terrain_hash :: proc(x, z: i32) -> f32 {
	h := transmute(u32)x * 0x27d4eb2d ~ transmute(u32)z * 0x165667b1
	h ~= h >> 16
	h *= 0x7feb352d
	h ~= h >> 15
	h *= 0x846ca68b
	h ~= h >> 16
	return f32(h) / 4294967295.0
}

terrain_smooth :: proc(e0, e1, x: f32) -> f32 {
	t := min(max((x - e0) / (e1 - e0), 0), 1)
	return t * t * (3 - 2 * t)
}

// Value noise in [0,1] with smoothstep-interpolated lattice.
terrain_vnoise :: proc(x, z: f32) -> f32 {
	xf := math.floor(x)
	zf := math.floor(z)
	xi := i32(xf)
	zi := i32(zf)
	tx := terrain_smooth(0, 1, x - xf)
	tz := terrain_smooth(0, 1, z - zf)
	a := terrain_hash(xi, zi)
	b := terrain_hash(xi + 1, zi)
	c := terrain_hash(xi, zi + 1)
	d := terrain_hash(xi + 1, zi + 1)
	top := a + (b - a) * tx
	bot := c + (d - c) * tx
	return top + (bot - top) * tz
}

terrain_mix :: proc(a, b: [3]f32, t: f32) -> [3]f32 {
	return a + (b - a) * t
}

terrain_height :: proc(x, z: f32) -> f32 {
	// Hills: wavelengths ~80/40/18 m, amplitude ~+-7 m.
	n := terrain_vnoise(x / 40, z / 40) * 0.5 +
		terrain_vnoise(x / 20 + 17.3, z / 20 - 9.1) * 0.3 +
		terrain_vnoise(x / 9 - 4.7, z / 9 + 31.9) * 0.2
	d := math.sqrt(x * x + z * z)
	// Spawn (radius < 14 m) stays at 1 m.
	hills := (n - 0.5) * 14 * terrain_smooth(14, 22, d)

	// Distant mountains: 0 at r=150, ~70 m at r=250, irregular skyline via low-freq noise.
	ridge := terrain_smooth(150, 250, d) * (0.7 + 0.3 * terrain_vnoise(x / 60 + 201.5, z / 60 - 77.2)) * 70
	return 1 + hills + ridge
}

terrain_normal :: proc(x, z: f32) -> [3]f32 {
	e: f32 = 0.5
	dx := (terrain_height(x + e, z) - terrain_height(x - e, z)) / (2 * e)
	dz := (terrain_height(x, z + e) - terrain_height(x, z - e)) / (2 * e)
	return linalg.normalize([3]f32{-dx, 1, -dz})
}

// 0 = open meadow, 1 = dense forest. About 40% forest, 35% meadow; forced 0 within 20 m of origin.
terrain_biome :: proc(x, z: f32) -> f32 {
	n := terrain_vnoise(x / 45 + 311.7, z / 45 - 58.3)
	d := math.sqrt(x * x + z * z)
	return terrain_smooth(0.42, 0.56, n) * terrain_smooth(20, 26, d)
}

// 0..1 flower patchiness, only in meadow (biome < 0.5), ~20% coverage.
terrain_flowers :: proc(x, z: f32) -> f32 {
	n := terrain_vnoise(x / 12.5 - 90.4, z / 12.5 + 13.7)
	meadow := 1 - terrain_smooth(0.45, 0.5, terrain_biome(x, z))
	return terrain_smooth(0.66, 0.76, n) * meadow
}

terrain_color :: proc(x, z: f32) -> [3]f32 {
	meadow := [3]f32{0.42, 0.70, 0.22}
	yellow := [3]f32{0.62, 0.78, 0.28}
	forest := [3]f32{0.24, 0.50, 0.22}
	dirt := [3]f32{0.50, 0.40, 0.26}
	rock := [3]f32{0.55, 0.54, 0.52}
	snow := [3]f32{0.80, 0.84, 0.88}

	h := terrain_height(x, z)
	n := terrain_normal(x, z)

	c := terrain_mix(meadow, yellow, terrain_smooth(0.55, 0.75, terrain_vnoise(x / 30 + 80, z / 30 - 40)))
	c = terrain_mix(c, forest, terrain_smooth(0.3, 0.7, terrain_biome(x, z)))
	// Dirt only on steep slopes (normal.y below ~0.75).
	c = terrain_mix(c, dirt, terrain_smooth(0.78, 0.70, n.y))
	c = terrain_mix(c, rock, terrain_smooth(40, 55, h))
	c = terrain_mix(c, snow, terrain_smooth(62, 72, h))
	return c
}

chunk_origin :: proc(cx, cz: int) -> (x, z: f32) {
	x = -WORLD_HALF + f32(cx) * CHUNK_SIZE
	z = -WORLD_HALF + f32(cz) * CHUNK_SIZE
	return
}

terrain_chunk :: proc(cx, cz: int, verts: ^[dynamic]gbbfx.VertexData, idx: ^[dynamic]u32) {
	ox, oz := chunk_origin(cx, cz)
	base := u32(len(verts))
	N :: TERRAIN_VERTS_PER_SIDE

	for j in 0 ..< N {
		for i in 0 ..< N {
			x := ox + f32(i)
			z := oz + f32(j)
			n := terrain_normal(x, z)
			c := terrain_color(x, z)
			append(verts, gbbfx.VertexData {
				position = {x, terrain_height(x, z), z},
				color    = {c.r, c.g, c.b, 1},
				uv       = {0, 0},
				normal   = n,
			})
		}
	}

	// Triangles wound CCW seen from above (+Y), i.e. front face up.
	for j in 0 ..< TERRAIN_CELLS_PER_SIDE {
		for i in 0 ..< TERRAIN_CELLS_PER_SIDE {
			a := base + u32(j * N + i)
			b := a + N // (i, j+1)
			c := a + 1 // (i+1, j)
			d := b + 1 // (i+1, j+1)
			append(idx, a, b, c, c, b, d)
		}
	}
}
