package city

import "core:testing"

@(test)
test_beacons_deterministic_inside_city_and_cover_skyscrapers :: proc(t: ^testing.T) {
	for seed in u32(1) ..< 4 {
		p := plan_build(seed)
		defer plan_destroy(&p)

		a, na := roof_lights_build(&p, seed)
		defer builder_destroy(&a)
		b, nb := roof_lights_build(&p, seed)
		defer builder_destroy(&b)
		testing.expectf(t, len(a.vertices) > 0, "seed %d: no roof lights", seed)
		testing.expectf(t, len(a.vertices) == len(b.vertices) && na == nb, "seed %d: light count differs between runs", seed)

		for q := 0; q < len(a.vertices); q += 4 {
			x, y, z := a.vertices[q].position.x, a.vertices[q].position.y, a.vertices[q].position.z
			testing.expectf(t, a.vertices[q].position == b.vertices[q].position, "seed %d: light %d differs between runs", seed, q / 4)
			testing.expectf(t, x >= 0 && x < CITY_SIZE && z >= 0 && z < CITY_SIZE, "seed %d: light %d outside city at (%v,%v)", seed, q / 4, x, z)
			testing.expectf(t, y > 0, "seed %d: light %d below ground at y=%v", seed, q / 4, y)
		}

		skyscrapers := 0
		for plot in p.buildings do if plot.tier == .Skyscraper do skyscrapers += 1
		testing.expectf(t, na >= skyscrapers, "seed %d: %d beacons for %d skyscrapers", seed, na, skyscrapers)
	}
}
