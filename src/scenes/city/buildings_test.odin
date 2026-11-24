package city

import "core:testing"

@(test)
test_building_indices_valid :: proc(t: ^testing.T) {
	gens := [4]Building_Proc{building_cube, building_blocky, building_modern, building_classic}
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
