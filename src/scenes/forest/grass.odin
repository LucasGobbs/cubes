package forest

import "core:math"
import "core:math/linalg"
import "core:testing"
import gbbfx "../../gbbfx"

// Blade = 5 verts (bottom pair, mid pair, tip) + 3 triangles (9 indices).
// lod 0: 20 blades/m2 * 256 m2 = 5120 blades = 25600 verts / 46080 indices per chunk (< 65535 u16-safe).
// lod 1: 5 blades/m2 = 1280 blades = 6400 verts / 11520 indices per chunk.
GRASS_DENSITY_LOD0 :: 20.0
GRASS_DENSITY_LOD1 :: 5.0
GRASS_BLADE_VERTS :: 5
GRASS_BLADE_INDICES :: 9

// Deterministic per-chunk stream (splitmix64); global rand is forbidden.
Grass_Rng :: struct {
	state: u64,
}

grass_rng_next :: proc(rng: ^Grass_Rng) -> f32 {
	rng.state += 0x9E3779B97F4A7C15
	z := rng.state
	z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ~ (z >> 27)) * 0x94D049BB133111EB
	z ~= z >> 31
	return f32(z >> 40) / f32(1 << 24)
}

grass_chunk :: proc(cx, cz: int, lod: int, verts: ^[dynamic]gbbfx.VertexData, idx: ^[dynamic]u32) {
	assert(lod == 0 || lod == 1, "grass_chunk: lod must be 0 or 1")
	density: f32 = GRASS_DENSITY_LOD0 if lod == 0 else GRASS_DENSITY_LOD1
	width_scale: f32 = 1 if lod == 0 else 1.9
	height_scale: f32 = 1 if lod == 0 else 1.15
	count := int(density * CHUNK_SIZE * CHUNK_SIZE)
	reserve(verts, len(verts) + count * GRASS_BLADE_VERTS)
	reserve(idx, len(idx) + count * GRASS_BLADE_INDICES)

	rng := Grass_Rng {
		state = u64(cx + 1) * 0x9E3779B97F4A7C15 ~ u64(cz + 1) * 0xC2B2AE3D27D4EB4F ~ u64(lod + 1) * 0x165667B19E3779F9,
	}
	ox, oz := chunk_origin(cx, cz)
	up := [3]f32{0, 1, 0}

	for _ in 0 ..< count {
		x := ox + grass_rng_next(&rng) * CHUNK_SIZE
		z := oz + grass_rng_next(&rng) * CHUNK_SIZE
		yaw := grass_rng_next(&rng) * 2 * math.PI
		lean := grass_rng_next(&rng) * 0.25
		h := (0.45 + grass_rng_next(&rng) * 0.5) * height_scale
		w := (0.04 + grass_rng_next(&rng) * 0.03) * width_scale
		tint := 0.85 + grass_rng_next(&rng) * 0.3

		base := [3]f32{x, terrain_height(x, z), z}
		// Blade plane spanned by r (across) and up; f is the lean direction and the front normal.
		r := [3]f32{math.cos(yaw), 0, math.sin(yaw)}
		f := [3]f32{-math.sin(yaw), 0, math.cos(yaw)}
		c_mid := base + up * (0.5 * h) + f * (lean * h * 0.25)
		c_tip := base + up * h + f * (lean * h)

		// Soft shading: half terrain normal, half up. Same for every vertex of the blade.
		n := linalg.normalize(terrain_normal(x, z) + up)
		t := terrain_color(x, z)
		col := [4]f32{min(t.x * tint, 1), min(t.y * tint, 1), min(t.z * tint, 1), 1}

		pos := [5][3]f32 {
			base - r * w,
			base + r * w,
			c_mid - r * (0.6 * w),
			c_mid + r * (0.6 * w),
			c_tip,
		}
		uv := [5][2]f32{{0, 1}, {0, 1}, {0.5, 1}, {0.5, 1}, {1, 1}}

		b := u32(len(verts))
		for i in 0 ..< GRASS_BLADE_VERTS {
			append(verts, gbbfx.VertexData{position = pos[i], color = col, uv = uv[i], normal = n})
		}
		tris := [9]u32{0, 1, 3, 0, 3, 2, 2, 3, 4}
		for i in tris do append(idx, b + i)
	}
}

@(test)
grass_chunk_counts :: proc(t: ^testing.T) {
	verts: [dynamic]gbbfx.VertexData
	idx: [dynamic]u32
	defer delete(verts)
	defer delete(idx)
	grass_chunk(3, 5, 0, &verts, &idx)
	testing.expect_value(t, len(verts), 25600)
	testing.expect_value(t, len(idx), 46080)
	clear(&verts)
	clear(&idx)
	grass_chunk(3, 5, 1, &verts, &idx)
	testing.expect_value(t, len(verts), 6400)
	testing.expect_value(t, len(idx), 11520)
}
