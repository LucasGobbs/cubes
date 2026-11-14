package forest_naive

import "core:math"

// Deterministic tree/rock/bush placements for the instanced forest. Also drives the
// physics colliders in both forests, so the ball hits the same trunks everywhere.
VARIANT_COUNT :: 13
VARIANT_OAK_FIRST :: 0 // 0..2
VARIANT_PINE_FIRST :: 3 // 3..4
VARIANT_BROAD_FIRST :: 5 // 5..6
VARIANT_AUTUMN :: 7
VARIANT_ROCK_FIRST :: 8 // 8..10
VARIANT_BUSH_FIRST :: 11 // 11..12

INSTANCE_CAP :: 40
INSTANCE_SCALE_MIN :: 0.8
INSTANCE_SCALE_MAX :: 1.4
ROCK_BURY :: 0.2

Instance :: struct {
	position: [3]f32,
	yaw, scale: f32,
	variant:  int,
}

// Deterministic placements for one chunk. Appends to `out`; at most INSTANCE_CAP per call.
placements_chunk :: proc(cx, cz: int, out: ^[dynamic]Instance) {
	x0, z0 := chunk_origin(cx, cz)
	seed := (u64(i64(cx)) * 0x9E3779B97F4A7C15) ~ (u64(i64(cz)) * 0xC2B2AE3D27D4EB4F) + 1
	rng := Tree_Rng{state = seed}
	biome := terrain_biome(x0 + CHUNK_SIZE / 2, z0 + CHUNK_SIZE / 2)

	placed := make([dynamic][2]f32, 0, 32)
	defer delete(placed)
	first := len(out)

	want := int(2 + 14 * biome + 0.5) + int(tree_rng_f32(&rng) * 3) - 1
	planted := 0
	for _ in 0 ..< 4 * want {
		if planted >= want || len(out) - first >= INSTANCE_CAP do break
		p, ok := tree_find_spot(&rng, x0, z0, TREE_EDGE_MARGIN, TREE_MIN_SPACING, placed[:])
		if !ok do continue
		p_biome := terrain_biome(p.x, p.y)
		if p_biome < 0.15 && tree_rng_f32(&rng) < 0.75 do continue
		h := terrain_height(p.x, p.y)
		if h > TREE_MAX_HEIGHT || terrain_normal(p.x, p.y).y < TREE_MAX_SLOPE_Y do continue
		append(&placed, p)
		planted += 1
		append(
			out,
			Instance {
				position = {p.x, h, p.y},
				yaw = tree_rng_range(&rng, 0, 2 * math.PI),
				scale = tree_rng_range(&rng, INSTANCE_SCALE_MIN, INSTANCE_SCALE_MAX),
				variant = tree_variant(&rng, p_biome),
			},
		)
	}

	for _ in 0 ..< 3 {
		if len(out) - first >= INSTANCE_CAP do break
		p, ok := tree_find_spot(&rng, x0, z0, PROP_EDGE_MARGIN, TREE_PROP_SPACING, placed[:])
		if !ok do continue
		append(&placed, p)
		scale := tree_rng_range(&rng, INSTANCE_SCALE_MIN, INSTANCE_SCALE_MAX)
		append(
			out,
			Instance {
				position = {p.x, terrain_height(p.x, p.y) - ROCK_BURY * scale, p.y},
				yaw = tree_rng_range(&rng, 0, 2 * math.PI),
				scale = scale,
				variant = VARIANT_ROCK_FIRST + int(tree_rng_f32(&rng) * 3),
			},
		)
	}

	for _ in 0 ..< 3 {
		if len(out) - first >= INSTANCE_CAP do break
		p, ok := tree_find_spot(&rng, x0, z0, PROP_EDGE_MARGIN, TREE_PROP_SPACING, placed[:])
		if !ok do continue
		append(&placed, p)
		append(
			out,
			Instance {
				position = {p.x, terrain_height(p.x, p.y), p.y},
				yaw = tree_rng_range(&rng, 0, 2 * math.PI),
				scale = tree_rng_range(&rng, INSTANCE_SCALE_MIN, INSTANCE_SCALE_MAX),
				variant = VARIANT_BUSH_FIRST + int(tree_rng_f32(&rng) * 2),
			},
		)
	}
}

tree_variant :: proc(rng: ^Tree_Rng, biome: f32) -> int {
	switch tree_pick_species(rng, biome) {
	case .Oak:
		return VARIANT_OAK_FIRST + int(tree_rng_f32(rng) * 3)
	case .Autumn:
		return VARIANT_AUTUMN
	case .Pine:
		return VARIANT_PINE_FIRST + int(tree_rng_f32(rng) * 2)
	case .Broad:
		return VARIANT_BROAD_FIRST + int(tree_rng_f32(rng) * 2)
	}
	return VARIANT_OAK_FIRST
}
