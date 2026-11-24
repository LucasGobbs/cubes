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
