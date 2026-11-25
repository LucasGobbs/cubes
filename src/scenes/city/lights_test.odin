package city

import "core:testing"

@(test)
test_lamps_on_street_cells_not_intersections :: proc(t: ^testing.T) {
	for seed in u32(1) ..< 6 {
		p := plan_build(seed)
		defer plan_destroy(&p)

		a := lamp_positions(&p, seed)
		defer delete(a)
		b := lamp_positions(&p, seed)
		defer delete(b)
		testing.expectf(t, len(a) > 0, "seed %d: no lamps", seed)
		testing.expectf(t, len(a) == len(b), "seed %d: lamp count differs between runs", seed)

		for pos, i in a {
			testing.expectf(t, pos == b[i], "seed %d: lamp %d differs between runs", seed, i)
			x, z := int(pos.x), int(pos.z)
			testing.expectf(
				t,
				x >= 0 && x < CITY_W && z >= 0 && z < CITY_D,
				"seed %d: lamp out of city at (%v,%v)",
				seed,
				pos.x,
				pos.z,
			)
			if x < 0 || x >= CITY_W || z < 0 || z >= CITY_D do continue
			testing.expectf(
				t,
				p.claimed[z * CITY_W + x] == CLAIM_ROAD,
				"seed %d: lamp off street at (%d,%d)",
				seed,
				x,
				z,
			)

			// A cell inside two road rects is an intersection; lamps must skip those.
			hits := 0
			for r in p.roads do if x >= int(r.x0) && x < int(r.x1) && z >= int(r.z0) && z < int(r.z1) do hits += 1
			testing.expectf(t, hits == 1, "seed %d: lamp in intersection at (%d,%d)", seed, x, z)
		}
	}
}
