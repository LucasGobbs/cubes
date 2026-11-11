package forest

import "core:math"
import "core:math/linalg"
import "core:testing"
import gbbfx "../../gbbfx"

// Tufts: ~0.5 clumps/m2, each clump scatters blades within 0.5 m so gaps show terrain.
// Blade = 7 verts (3 rows of pairs + tip), 5 tris = 15 indices. Flower = stem blade + 6-vert fan head.
// lod 0 typical per chunk: 128 clumps * 18 blades = 2304 blades = 16128 verts; + flowers (<=45 * 13) => <= ~16.7k verts.
// lod 1 typical per chunk: 128 clumps * 5 blades = 640 blades = 4480 verts; + flowers => <= ~5k verts.
GRASS_CLUMPS_PER_M2 :: 0.5
GRASS_BLADES_LOD0 :: 18
GRASS_BLADES_LOD1 :: 5
GRASS_BLADE_VERTS :: 7
GRASS_BLADE_INDICES :: 15
GRASS_HEAD_VERTS :: 6
GRASS_HEAD_INDICES :: 15
GRASS_FLOWER_PATCH :: 12.0
GRASS_YELLOW :: [3]f32{0.85, 0.8, 0.25}
GRASS_STEM_GREEN :: [3]f32{0.35, 0.6, 0.2}
GRASS_FLOWER_COLORS := [4][3]f32{{0.95, 0.95, 0.9}, {1.0, 0.85, 0.2}, {0.95, 0.5, 0.65}, {0.45, 0.55, 1.0}}

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

Grass_Blade :: struct {
	base:       [3]f32,
	yaw, lean:  f32, // width direction, bend direction (radians, horizontal)
	bend, h, w: f32, // tip horizontal offset / height, full width
	root, tip:  [3]f32,
	normal:     [3]f32,
	kind:       f32,
}

grass_saturate :: proc(c: [3]f32) -> [3]f32 {
	return {min(c.x, 1), min(c.y, 1), min(c.z, 1)}
}

grass_rgba :: proc(c: [3]f32) -> [4]f32 {
	return {c.x, c.y, c.z, 1}
}

grass_emit_blade :: proc(verts: ^[dynamic]gbbfx.VertexData, idx: ^[dynamic]u32, bl: Grass_Blade) {
	r := [3]f32{math.cos(bl.yaw), 0, math.sin(bl.yaw)}
	f := [3]f32{math.cos(bl.lean), 0, math.sin(bl.lean)}
	b := u32(len(verts))
	rows := [3]f32{1, 0.85, 0.55}
	for i in 0 ..< 3 {
		s := f32(i) / 3
		c := bl.base + [3]f32{0, bl.h * s, 0} + f * (bl.bend * bl.h * s * s)
		hw := bl.w * 0.5 * rows[i]
		col := grass_rgba(linalg.lerp(bl.root, bl.tip, s))
		append(verts, gbbfx.VertexData{position = c - r * hw, color = col, uv = {s, bl.kind}, normal = bl.normal})
		append(verts, gbbfx.VertexData{position = c + r * hw, color = col, uv = {s, bl.kind}, normal = bl.normal})
	}
	tc := bl.base + [3]f32{0, bl.h, 0} + f * (bl.bend * bl.h)
	append(verts, gbbfx.VertexData{position = tc, color = grass_rgba(bl.tip), uv = {1, bl.kind}, normal = bl.normal})
	tris := [GRASS_BLADE_INDICES]u32{0, 1, 3, 0, 3, 2, 2, 3, 5, 2, 5, 4, 4, 5, 6}
	for i in tris do append(idx, b + i)
}

// Flat fan head: centre + 5 rim points on a plane tilted toward the stem lean.
grass_emit_head :: proc(verts: ^[dynamic]gbbfx.VertexData, idx: ^[dynamic]u32, centre: [3]f32, yaw, radius: f32, petal, normal: [3]f32) {
	e1 := [3]f32{math.cos(yaw), 0, math.sin(yaw)}
	e2 := [3]f32{-math.sin(yaw), 0, math.cos(yaw)} * 0.8 + [3]f32{0, 0.6, 0}
	b := u32(len(verts))
	col := grass_rgba(petal)
	append(verts, gbbfx.VertexData{position = centre, color = col, uv = {1, 1}, normal = normal})
	for k in 0 ..< 5 {
		a := f32(k) * 2 * math.PI / 5
		p := centre + e1 * (math.cos(a) * radius) + e2 * (math.sin(a) * radius)
		append(verts, gbbfx.VertexData{position = p, color = col, uv = {1, 1}, normal = normal})
	}
	for k in 0 ..< 5 {
		append(idx, b)
		append(idx, b + 1 + u32(k))
		append(idx, b + 1 + u32((k + 1) % 5))
	}
}

grass_chunk :: proc(cx, cz: int, lod: int, verts: ^[dynamic]gbbfx.VertexData, idx: ^[dynamic]u32) {
	assert(lod == 0 || lod == 1, "grass_chunk: lod must be 0 or 1")
	blades_per_clump := GRASS_BLADES_LOD0 if lod == 0 else GRASS_BLADES_LOD1
	width_scale: f32 = 1 if lod == 0 else 2.2
	height_scale: f32 = 1 if lod == 0 else 1.2
	clumps := int(GRASS_CLUMPS_PER_M2 * CHUNK_SIZE * CHUNK_SIZE)
	reserve(verts, len(verts) + clumps * blades_per_clump * GRASS_BLADE_VERTS)
	reserve(idx, len(idx) + clumps * blades_per_clump * GRASS_BLADE_INDICES)

	rng := Grass_Rng {
		state = u64(cx + 1) * 0x9E3779B97F4A7C15 ~ u64(cz + 1) * 0xC2B2AE3D27D4EB4F ~ u64(lod + 1) * 0x165667B19E3779F9,
	}
	ox, oz := chunk_origin(cx, cz)
	up := [3]f32{0, 1, 0}

	for _ in 0 ..< clumps {
		// All rolls drawn up front so the stream does not depend on which clumps are skipped.
		x0 := ox + grass_rng_next(&rng) * CHUNK_SIZE
		z0 := oz + grass_rng_next(&rng) * CHUNK_SIZE
		clump_yaw := grass_rng_next(&rng) * 2 * math.PI
		tint := 0.9 + grass_rng_next(&rng) * 0.2
		yellow := grass_rng_next(&rng) < 0.15
		forest_skip := grass_rng_next(&rng) < 0.7
		flower_roll := grass_rng_next(&rng) < 0.35

		if terrain_height(x0, z0) > 40 || terrain_normal(x0, z0).y < 0.75 do continue
		biome := terrain_biome(x0, z0)
		if biome > 0.6 && forest_skip do continue
		dark: f32 = 0.8 if biome > 0.6 else 1

		for _ in 0 ..< blades_per_clump {
			ang := grass_rng_next(&rng) * 2 * math.PI
			rad := math.sqrt(grass_rng_next(&rng)) * 0.5
			x := x0 + math.cos(ang) * rad
			z := z0 + math.sin(ang) * rad
			h := (0.30 + grass_rng_next(&rng) * 0.35) * height_scale
			w := (0.07 + grass_rng_next(&rng) * 0.04) * width_scale
			lean := clump_yaw + (grass_rng_next(&rng) - 0.5) * 0.6
			bend := 0.25 + grass_rng_next(&rng) * 0.25
			yaw := grass_rng_next(&rng) * 2 * math.PI

			root := terrain_color(x, z)
			tip := root * (tint * dark)
			if yellow do tip = linalg.lerp(tip, GRASS_YELLOW, f32(0.25))
			n := linalg.normalize(terrain_normal(x, z) * 0.7 + up * 0.3)
			grass_emit_blade(verts, idx, Grass_Blade {
				base = {x, terrain_height(x, z), z},
				yaw = yaw, lean = lean, bend = bend, h = h, w = w,
				root = root, tip = grass_saturate(tip), normal = n, kind = 1,
			})
		}

		if flower_roll && terrain_flowers(x0, z0) > 0.4 {
			base := [3]f32{x0, terrain_height(x0, z0), z0}
			n := linalg.normalize(terrain_normal(x0, z0) * 0.7 + up * 0.3)
			stem_h := 0.35 + grass_rng_next(&rng) * 0.25
			yaw := grass_rng_next(&rng) * 2 * math.PI
			bend: f32 = 0.15
			grass_emit_blade(verts, idx, Grass_Blade {
				base = base, yaw = yaw, lean = clump_yaw, bend = bend, h = stem_h, w = 0.03,
				root = terrain_color(x0, z0), tip = GRASS_STEM_GREEN, normal = n, kind = 1,
			})
			f := [3]f32{math.cos(clump_yaw), 0, math.sin(clump_yaw)}
			tip := base + up * stem_h + f * (bend * stem_h)
			cell_x := i32(math.floor(x0 / GRASS_FLOWER_PATCH))
			cell_z := i32(math.floor(z0 / GRASS_FLOWER_PATCH))
			pick := min(int(terrain_hash(cell_x, cell_z) * 4), 3)
			grass_emit_head(verts, idx, tip + up * 0.02, yaw, 0.06, GRASS_FLOWER_COLORS[pick], n)
		}
	}
}

@(test)
grass_chunk_budget :: proc(t: ^testing.T) {
	verts: [dynamic]gbbfx.VertexData
	idx: [dynamic]u32
	defer delete(verts)
	defer delete(idx)
	counts: [2]int
	for lod in 0 ..< 2 {
		clear(&verts)
		clear(&idx)
		grass_chunk(3, 5, lod, &verts, &idx)
		counts[lod] = len(verts)
		testing.expect(t, len(verts) < 65535)
		testing.expect(t, len(idx) % 3 == 0)
		in_range := true
		for i in idx do if int(i) >= len(verts) do in_range = false
		testing.expect(t, in_range)
	}
	testing.expect(t, counts[0] > counts[1])
}
