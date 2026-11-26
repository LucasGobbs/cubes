package city

import "core:testing"

@(test)
test_building_indices_valid :: proc(t: ^testing.T) {
	gens := [10]Building_Proc{building_cube, building_blocky, building_modern, building_tower, building_stepped, building_slab, building_twin, building_lshape, building_warehouse, building_supertall}
	for gen, k in gens {
		for seed in u32(1) ..< 64 {
			b: Mesh_Builder
			rng := rng_seed(seed)
			gen(&b, &rng, {0, 0, 0}, {24, 24}, 24)
			testing.expectf(t, len(b.indices) % 3 == 0, "generator %d seed %d: index count %d not a multiple of 3", k, seed, len(b.indices))
			for idx in b.indices {
				testing.expectf(t, int(idx) < len(b.vertices), "generator %d seed %d: index %d >= vertex count %d", k, seed, idx, len(b.vertices))
			}
			builder_destroy(&b)
		}
	}
}

@(test)
test_city_mesh_same_seed_same_mesh :: proc(t: ^testing.T) {
	p := plan_build(7)
	defer plan_destroy(&p)
	a := city_build_mesh(&p, 7)
	defer builder_destroy(&a)
	b := city_build_mesh(&p, 7)
	defer builder_destroy(&b)
	testing.expect(t, len(a.vertices) > 0, "city has no vertices")
	testing.expectf(t, len(a.vertices) == len(b.vertices), "same seed, vertex counts %d vs %d", len(a.vertices), len(b.vertices))
	testing.expectf(t, len(a.indices) == len(b.indices), "same seed, index counts %d vs %d", len(a.indices), len(b.indices))
}

@(test)
test_block_walls_continuous_u :: proc(t: ^testing.T) {
	// Wall k+1 starts one window before wall k ends, so the corner column is shared (no mirror).
	b: Mesh_Builder
	defer builder_destroy(&b)
	f := Facade{color = {1, 1, 1, 1}, tile = 3, uv = {0.25, 0.5}}
	building_block(&b, f, Rect{x0 = 0, x1 = 10, z0 = 0, z1 = 6}, 0, 4)
	widths := [4]f32{10, 10, 6, 6} // sides +Z, -Z, +X, -X
	u := f.uv.x
	for k in 0 ..< 4 {
		start := b.vertices[4 * k].uv.x
		end := b.vertices[4 * k + 1].uv.x
		testing.expectf(t, abs(start - u) < 1e-5, "wall %d starts at u %v, want %v", k, start, u)
		testing.expectf(t, abs(end - start - widths[k] * WINDOW_UV) < 1e-5, "wall %d spans %v, want %v", k, end - start, widths[k] * WINDOW_UV)
		u = end - WINDOW_UV
	}
}

@(test)
test_tower_within_stories :: proc(t: ^testing.T) {
	// Tiers and lids stack to exactly `stories`; the antenna adds at most 8 more. Walls stay within one unit of the footprint.
	sizes := [2][3]f32{{18, 18, 24}, {10, 14, 30}} // footprint x, footprint z, stories
	for size in sizes {
		footprint := [2]f32{size.x, size.y}
		stories := int(size.z)
		for seed in u32(1) ..< 128 {
			b: Mesh_Builder
			rng := rng_seed(seed)
			building_tower(&b, &rng, {100, 0, 200}, footprint, stories)
			top: f32 = -1
			for v in b.vertices {
				top = max(top, v.position.y)
				testing.expectf(t, abs(v.position.x - 100) <= footprint.x / 2 + 1, "seed %d: x %v outside footprint", seed, v.position.x)
				testing.expectf(t, abs(v.position.z - 200) <= footprint.y / 2 + 1, "seed %d: z %v outside footprint", seed, v.position.z)
			}
			testing.expectf(t, top <= f32(stories) + 8, "seed %d: top %v above stories %d", seed, top, stories)
			testing.expectf(t, top >= f32(stories), "seed %d: top %v below stories %d", seed, top, stories)
			builder_destroy(&b)
		}
	}
}

@(test)
test_supertall_within_stories :: proc(t: ^testing.T) {
	// Tiers, lids and crown stack to `stories`; crown, pinnacle and antenna add at most SUPERTALL_TOP_MAX more.
	sizes := [2][3]f32{{26, 26, 160}, {40, 32, 260}} // footprint x, footprint z, stories
	for size in sizes {
		footprint := [2]f32{size.x, size.y}
		stories := int(size.z)
		for seed in u32(1) ..< 32 {
			b: Mesh_Builder
			rng := rng_seed(seed)
			building_supertall(&b, &rng, {100, 0, 200}, footprint, stories)
			top: f32 = -1
			for v in b.vertices {
				top = max(top, v.position.y)
				testing.expectf(t, abs(v.position.x - 100) <= footprint.x / 2 + 1, "seed %d: x %v outside footprint", seed, v.position.x)
				testing.expectf(t, abs(v.position.z - 200) <= footprint.y / 2 + 1, "seed %d: z %v outside footprint", seed, v.position.z)
			}
			testing.expectf(t, top <= f32(stories + SUPERTALL_TOP_MAX), "seed %d: top %v above stories %d", seed, top, stories)
			testing.expectf(t, top >= f32(stories), "seed %d: top %v below stories %d", seed, top, stories)
			testing.expectf(t, len(b.vertices) <= 3000, "seed %d: %d vertices", seed, len(b.vertices))
			builder_destroy(&b)
		}
	}
}

@(test)
test_supertall_deterministic :: proc(t: ^testing.T) {
	a, b: Mesh_Builder
	defer builder_destroy(&a)
	defer builder_destroy(&b)
	ra := rng_seed(9)
	rb := rng_seed(9)
	building_supertall(&a, &ra, {0, 0, 0}, {30, 30}, 200)
	building_supertall(&b, &rb, {0, 0, 0}, {30, 30}, 200)
	testing.expectf(t, len(a.vertices) == len(b.vertices), "same seed: %d vs %d vertices", len(a.vertices), len(b.vertices))
	for i in 0 ..< min(len(a.vertices), len(b.vertices)) {
		testing.expectf(t, a.vertices[i].position == b.vertices[i].position, "same seed, vertex %d differs", i)
	}
}
