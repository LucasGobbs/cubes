package forest

import "core:math"
import "core:math/linalg"
import gbbfx "../../gbbfx"

WORLD_HALF :: 128.0
CHUNK_SIZE :: 16.0
CHUNKS_PER_SIDE :: 16

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

terrain_height :: proc(x, z: f32) -> f32 {
	// Three octaves, wavelengths ~40 m, ~20 m, ~10 m; sum of weights 1 keeps the result in [0,1].
	n := terrain_vnoise(x / 40, z / 40) * 0.5 +
		terrain_vnoise(x / 20 + 17.3, z / 20 - 9.1) * 0.3 +
		terrain_vnoise(x / 10 - 4.7, z / 10 + 31.9) * 0.2
	h := (n - 0.5) * 10 // amplitude ~ +-5 m

	// Flatten toward 1 m around the camera spawn (origin).
	d := math.sqrt(x * x + z * z)
	w := terrain_smooth(4, 12, d)
	return 1 + (h - 1) * w
}

terrain_normal :: proc(x, z: f32) -> [3]f32 {
	e: f32 = 0.5
	dx := (terrain_height(x + e, z) - terrain_height(x - e, z)) / (2 * e)
	dz := (terrain_height(x, z + e) - terrain_height(x, z - e)) / (2 * e)
	return linalg.normalize([3]f32{-dx, 1, -dz})
}

terrain_color :: proc(x, z: f32) -> [3]f32 {
	green := [3]f32{0.30, 0.55, 0.18}
	yellow := [3]f32{0.55, 0.65, 0.20}
	dirt := [3]f32{0.42, 0.33, 0.20}

	// Low-frequency patches of yellow-green meadow.
	patch := terrain_smooth(0.55, 0.75, terrain_vnoise(x / 30 + 80, z / 30 - 40))
	c := green + (yellow - green) * (patch * 0.6)

	// Dirt only where the slope is steep (normal.y small).
	steep := 1 - terrain_smooth(0.6, 0.8, terrain_normal(x, z).y)
	return c + (dirt - c) * steep
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
