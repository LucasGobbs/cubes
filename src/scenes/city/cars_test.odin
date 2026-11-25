package city

import "core:testing"

@(test)
test_cars_on_streets_and_deterministic :: proc(t: ^testing.T) {
	for seed in u32(1) ..< 4 {
		p := plan_build(seed)
		defer plan_destroy(&p)

		a := cars_build(&p, seed)
		defer builder_destroy(&a)
		b := cars_build(&p, seed)
		defer builder_destroy(&b)
		testing.expectf(t, len(a.vertices) > 0, "seed %d: no cars", seed)
		testing.expectf(t, len(a.vertices) == len(b.vertices), "seed %d: car count differs between runs", seed)
		testing.expectf(t, len(a.vertices) % CAR_VERTICES == 0, "seed %d: partial car", seed)

		for i in 0 ..< len(a.vertices) / 4 {
			v := a.vertices[4 * i]
			testing.expectf(t, v.position == b.vertices[4 * i].position, "seed %d: vertex %d differs between runs", seed, 4 * i)
			testing.expectf(t, v.uv.x >= CAR_SPEED_MIN && v.uv.x <= CAR_SPEED_MAX, "seed %d: speed %v out of range", seed, v.uv.x)
		}

		// Lamp centres (average of each quad's corners) at the start pose must sit on a street cell.
		for q in 0 ..< len(a.vertices) / 4 {
			c: Vec3
			for k in 0 ..< 4 do c += a.vertices[4 * q + k].position
			c /= 4
			x, z := int(c.x), int(c.z)
			if x < 0 || x >= CITY_W || z < 0 || z >= CITY_D {
				testing.expectf(t, false, "seed %d: lamp %d outside city at (%v,%v)", seed, q, c.x, c.z)
				continue
			}
			testing.expectf(t, p.claimed[z * CITY_W + x] == CLAIM_ROAD, "seed %d: lamp %d off street at (%d,%d)", seed, q, x, z)
		}
	}
}
