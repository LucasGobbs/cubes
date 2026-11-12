// Instanced grass: a clump of blades is one small mesh (a tuft) in local space,
// and every clump in the world is an instance of one. Variants = shape x root
// colour bucket x LOD (the instanced shader only gets a matrix per instance, so
// the root colour that blends with the terrain is quantised into a few
// buckets), plus one flower variant per petal colour.
package forest_instanced

import "core:math"
import "core:math/linalg"
import gfx "../../engine/gfx"
import naive "../forest_naive"

TUFT_SHAPES :: 3
TUFT_COLORS :: 4
TUFT_LOD_COUNT :: TUFT_SHAPES * TUFT_COLORS
FLOWER_BASE :: 2 * TUFT_LOD_COUNT
TUFT_COUNT :: FLOWER_BASE + 4

// Root colours the terrain palette is snapped to: meadow, yellow-green, mid, forest floor.
TUFT_PALETTE := [TUFT_COLORS][3]f32{{0.42, 0.70, 0.22}, {0.62, 0.78, 0.28}, {0.50, 0.74, 0.25}, {0.24, 0.50, 0.22}}

Grass_Instance :: struct {
	position:    [3]f32,
	yaw, scale:  f32,
	lod0, lod1:  int, // variant index per LOD (equal for flowers)
}

tuft_variant :: proc(lod, shape, color: int) -> int {
	return lod * TUFT_LOD_COUNT + shape * TUFT_COLORS + color
}

tufts_build :: proc() -> (out: [TUFT_COUNT]Variant_Data) {
	verts: [dynamic]gfx.VertexData
	idx: [dynamic]u32
	defer delete(verts)
	defer delete(idx)
	up := [3]f32{0, 1, 0}

	for lod in 0 ..< 2 {
		blades := naive.GRASS_BLADES_LOD0 if lod == 0 else naive.GRASS_BLADES_LOD1
		width_scale: f32 = 1 if lod == 0 else 2.2
		height_scale: f32 = 1 if lod == 0 else 1.2
		for shape in 0 ..< TUFT_SHAPES {
			for color in 0 ..< TUFT_COLORS {
				clear(&verts)
				clear(&idx)
				// Same seed for every colour of a shape/LOD: colour buckets differ only in colour.
				rng := naive.Grass_Rng{state = u64(shape + 1) * 0x9E3779B97F4A7C15 ~ u64(lod + 1) * 0xC2B2AE3D27D4EB4F}
				clump_yaw := naive.grass_rng_next(&rng) * 2 * math.PI
				tint := 0.92 + f32(shape) * 0.06
				root := TUFT_PALETTE[color]
				for _ in 0 ..< blades {
					ang := naive.grass_rng_next(&rng) * 2 * math.PI
					rad := math.sqrt(naive.grass_rng_next(&rng)) * 0.5
					naive.grass_emit_blade(&verts, &idx, naive.Grass_Blade {
						base = {math.cos(ang) * rad, 0, math.sin(ang) * rad},
						yaw = naive.grass_rng_next(&rng) * 2 * math.PI,
						lean = clump_yaw + (naive.grass_rng_next(&rng) - 0.5) * 0.6,
						bend = 0.25 + naive.grass_rng_next(&rng) * 0.25,
						h = (0.30 + naive.grass_rng_next(&rng) * 0.35) * height_scale,
						w = (0.07 + naive.grass_rng_next(&rng) * 0.04) * width_scale,
						root = root, tip = naive.grass_saturate(root * tint), normal = up, kind = 1,
					})
				}
				tuft_narrow(&out[tuft_variant(lod, shape, color)], verts[:], idx[:])
			}
		}
	}

	for petal, k in naive.GRASS_FLOWER_COLORS {
		clear(&verts)
		clear(&idx)
		stem_h: f32 = 0.45
		naive.grass_emit_blade(&verts, &idx, naive.Grass_Blade {
			lean = 0, bend = 0.15, h = stem_h, w = 0.03,
			root = TUFT_PALETTE[0], tip = naive.GRASS_STEM_GREEN, normal = up, kind = 1,
		})
		head := [3]f32{0.15 * stem_h, stem_h + 0.02, 0}
		naive.grass_emit_head(&verts, &idx, head, 0.7, 0.06, petal, up)
		tuft_narrow(&out[FLOWER_BASE + k], verts[:], idx[:])
	}
	return
}

tuft_narrow :: proc(data: ^Variant_Data, verts: []gfx.VertexData, idx: []u32) {
	assert(len(verts) < 1 << 16)
	append(&data.verts, ..verts)
	for i in idx do append(&data.idx, u16(i))
}

// Clump placement for one chunk; deterministic per (cx, cz), same rules as the
// baked naive grass (no grass on steep or high ground, sparse in dense forest).
grass_placements :: proc(cx, cz: int, out: ^[dynamic]Grass_Instance) {
	rng := naive.Grass_Rng{state = u64(cx + 1) * 0x9E3779B97F4A7C15 ~ u64(cz + 1) * 0xC2B2AE3D27D4EB4F ~ 0x165667B19E3779F9}
	ox, oz := naive.chunk_origin(cx, cz)
	clumps := int(naive.GRASS_CLUMPS_PER_M2 * naive.CHUNK_SIZE * naive.CHUNK_SIZE)
	for _ in 0 ..< clumps {
		// All rolls drawn up front so the stream does not depend on which clumps are skipped.
		x := ox + naive.grass_rng_next(&rng) * naive.CHUNK_SIZE
		z := oz + naive.grass_rng_next(&rng) * naive.CHUNK_SIZE
		yaw := naive.grass_rng_next(&rng) * 2 * math.PI
		scale := 0.85 + naive.grass_rng_next(&rng) * 0.3
		shape := min(int(naive.grass_rng_next(&rng) * TUFT_SHAPES), TUFT_SHAPES - 1)
		forest_skip := naive.grass_rng_next(&rng) < 0.7
		flower_roll := naive.grass_rng_next(&rng) < 0.35

		if naive.terrain_height(x, z) > 40 || naive.terrain_normal(x, z).y < 0.75 do continue
		biome := naive.terrain_biome(x, z)
		if biome > 0.6 && forest_skip do continue

		color := naive.terrain_color(x, z)
		best, best_distance := 0, f32(1e9)
		for candidate, i in TUFT_PALETTE {
			d := linalg.length2(candidate - color)
			if d < best_distance do best, best_distance = i, d
		}
		position := [3]f32{x, naive.terrain_height(x, z), z}
		append(out, Grass_Instance{position, yaw, scale, tuft_variant(0, shape, best), tuft_variant(1, shape, best)})

		if flower_roll && naive.terrain_flowers(x, z) > 0.4 {
			cell_x := i32(math.floor(x / naive.GRASS_FLOWER_PATCH))
			cell_z := i32(math.floor(z / naive.GRASS_FLOWER_PATCH))
			pick := FLOWER_BASE + min(int(naive.terrain_hash(cell_x, cell_z) * 4), 3)
			append(out, Grass_Instance{position, yaw, 1, pick, pick})
		}
	}
}
