package city

import "core:testing"

@(test)
test_plan_plots_disjoint_inside_city_off_roads :: proc(t: ^testing.T) {
	for seed in u32(1) ..< 6 {
		p := plan_build(seed)
		defer plan_destroy(&p)

		road := make([]bool, CITY_CELLS)
		defer delete(road)
		for r in p.roads {
			for z in r.z0 ..< r.z1 {
				for x in r.x0 ..< r.x1 do road[z * CITY_W + x] = true
			}
		}

		occupied := make([]u8, CITY_CELLS)
		defer delete(occupied)
		for plot in p.buildings {
			testing.expectf(
				t,
				plot.x >= 0 && plot.z >= 0 && plot.x + plot.w <= CITY_W && plot.z + plot.d <= CITY_D,
				"seed %d: plot out of city at (%d,%d) %dx%d",
				seed,
				plot.x,
				plot.z,
				plot.w,
				plot.d,
			)
			if plot.x < 0 || plot.z < 0 || plot.x + plot.w > CITY_W || plot.z + plot.d > CITY_D do continue
			for z in plot.z ..< plot.z + plot.d {
				for x in plot.x ..< plot.x + plot.w {
					i := z * CITY_W + x
					testing.expectf(t, occupied[i] == 0, "seed %d: plots overlap at (%d,%d)", seed, x, z)
					testing.expectf(t, !road[i], "seed %d: plot on road at (%d,%d)", seed, x, z)
					occupied[i] = 1
				}
			}
		}
	}
}

@(test)
test_plan_same_seed_same_plots :: proc(t: ^testing.T) {
	a := plan_build(7)
	defer plan_destroy(&a)
	b := plan_build(7)
	defer plan_destroy(&b)
	testing.expectf(t, len(a.buildings) == len(b.buildings), "same seed, plot counts %d vs %d", len(a.buildings), len(b.buildings))
	testing.expectf(t, len(a.roads) == len(b.roads), "same seed, road counts %d vs %d", len(a.roads), len(b.roads))
	for i in 0 ..< min(len(a.buildings), len(b.buildings)) {
		testing.expectf(t, a.buildings[i] == b.buildings[i], "same seed, plot %d differs", i)
	}
}

@(test)
test_plan_skyscraper_count :: proc(t: ^testing.T) {
	for seed in u32(1) ..< 6 {
		p := plan_build(seed)
		defer plan_destroy(&p)
		n := 0
		for plot in p.buildings do if plot.tier == .Skyscraper do n += 1
		testing.expectf(t, n >= 15, "seed %d: only %d skyscrapers placed", seed, n)
	}
}

@(test)
test_plan_supertalls :: proc(t: ^testing.T) {
	rules := tier_rules[.Supertall]
	for seed in u32(1) ..< 6 {
		p := plan_build(seed)
		defer plan_destroy(&p)
		n := 0
		for plot in p.buildings do if plot.tier == .Supertall {
			n += 1
			testing.expectf(t, plot.kind == .Supertall, "seed %d: supertall plot has kind %v", seed, plot.kind)
			testing.expectf(t, plot.w >= rules.footprint_min && plot.d >= rules.footprint_min, "seed %d: footprint %v x %v too small", seed, plot.w, plot.d)
			testing.expectf(t, plot.w <= rules.footprint_max && plot.d <= rules.footprint_max, "seed %d: footprint %v x %v too big", seed, plot.w, plot.d)
			testing.expectf(t, int(plot.stories) >= rules.stories_min && int(plot.stories) <= rules.stories_max, "seed %d: stories %d", seed, plot.stories)
			testing.expectf(t, plot.x >= SUPERTALL_EDGE && plot.z >= SUPERTALL_EDGE, "seed %d: supertall too near min edge", seed)
			testing.expectf(t, plot.x + plot.w <= CITY_W - SUPERTALL_EDGE && plot.z + plot.d <= CITY_D - SUPERTALL_EDGE, "seed %d: supertall too near max edge", seed)
		}
		testing.expectf(t, n >= 8 && n <= 14, "seed %d: %d supertalls placed", seed, n)
	}
}
