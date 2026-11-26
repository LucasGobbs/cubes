// Aviation beacons and roof lights, as camera-facing billboards in one mesh (see beacons.odin). Each tall building is
// replayed through its own generator, so lights sit on the drawn geometry: a beacon at the highest point (antenna tip,
// clutter, or roof), roof lights at the corners of the top roof or on a ring round a modern cylinder.
package city

import gfx "../../engine/gfx"
import "core:math"

ROOF_BEACON_MIN_STORIES :: 55 // skyscrapers and the tallest mediums
BEACON_HEIGHT :: 0.5 // beacon centre above the highest point of the building
BEACON_WIDTH :: 2.5
BEACON_TINT :: [3]f32{2.5, 0.05, 0.03} // HDR red: the shader's core (1.6x) lands near 4
BEACON_PERIOD_MIN :: 1.2
BEACON_PERIOD_MAX :: 2.2
ROOF_LIGHT_WIDTH :: 1.2
ROOF_LIGHT_LIFT :: 0.3 // roof light centre above the roof
ROOF_LIGHT_INSET :: 0.5 // corner lights sit this far inside the roof corner
ROOF_LIGHT_BLINK_CHANCE :: 0.3 // share of roof lights that blink; the rest are steady
ROOF_RING_COUNT :: 12
ROOF_RING_CHANCE :: 3 // one modern cylinder in this many gets a ring
// Ring radius as a share of the cylinder's half-size: inside every cut chord, so no light hangs off the roof.
ROOF_RING_RADIUS :: 0.6
ROOF_SEED_MIX :: 0x6A09E667

// Per-light vertex data: color = {corner.x, corner.y, blink phase, blink period}, uv = {blink flag, width},
// normal = HDR tint.
roof_light_add :: proc(b: ^Mesh_Builder, c: Vec3, tint: [3]f32, width: f32, blink: bool, phase, period: f32) {
	corners := [4][2]f32{{-1, -1}, {1, -1}, {1, 1}, {-1, 1}}
	base := u32(len(b.vertices))
	for k in 0 ..< 4 {
		append(
			&b.vertices,
			gfx.VertexData {
				position = c,
				color = {corners[k].x, corners[k].y, phase, period},
				uv = {1 if blink else 0, width},
				normal = tint,
			},
		)
	}
	append(&b.indices, base, base + 1, base + 2, base, base + 2, base + 3)
}

// Lights for every building of tier Medium or Skyscraper. Returns the mesh and the beacon count (one per building
// of ROOF_BEACON_MIN_STORIES or more). Each building reuses its generator's stream, so the lights match the geometry.
roof_lights_build :: proc(p: ^Plan, seed: u32) -> (out: Mesh_Builder, beacons: int) {
	scratch: Mesh_Builder
	defer builder_destroy(&scratch)
	for plot, i in p.buildings {
		if plot.tier == .Small || plot.kind == .Warehouse do continue
		clear(&scratch.vertices)
		clear(&scratch.indices)
		building_emit(&scratch, p, seed, i)
		vs := scratch.vertices[:]
		rng := rng_seed(seed ~ ROOF_SEED_MIX ~ (u32(i + 1) * BUILDING_SEED_MIX))
		rng_u32(&rng) // first output of a near-zero xorshift state is weakly mixed

		if plot.stories >= ROOF_BEACON_MIN_STORIES {
			top := highest_y(vs)
			r := bounds_at(vs, top)
			c := Vec3{(r.x0 + r.x1) / 2, top + BEACON_HEIGHT, (r.z0 + r.z1) / 2}
			roof_light_add(&out, c, BEACON_TINT, BEACON_WIDTH, true, rng_f32(&rng), rng_range(&rng, BEACON_PERIOD_MIN, BEACON_PERIOD_MAX))
			beacons += 1
		}

		if plot.kind == .Supertall {
			supertall_warning_lights(&out, vs, int(plot.stories))
			continue
		}
		top := f32(plot.stories)
		r := bounds_at(vs, top)
		if r.x1 < r.x0 do continue // no geometry at the stories line: nothing to light
		if plot.kind == .Modern {
			if rng_int(&rng, 0, ROOF_RING_CHANCE - 1) != 0 do continue
			cx, cz := (r.x0 + r.x1) / 2, (r.z0 + r.z1) / 2
			hx, hz := (r.x1 - r.x0) / 2 * ROOF_RING_RADIUS, (r.z1 - r.z0) / 2 * ROOF_RING_RADIUS
			for k in 0 ..< ROOF_RING_COUNT {
				a := f32(k) * math.TAU / ROOF_RING_COUNT
				c := Vec3{cx + hx * math.cos(a), top + ROOF_LIGHT_LIFT, cz + hz * math.sin(a)}
				roof_light_add(&out, c, {1, 0.95, 0.85}, ROOF_LIGHT_WIDTH, false, 0, 1)
			}
			continue
		}
		// Box tops: 1..4 consecutive corners from a random start.
		k := rng_int(&rng, 1, 4)
		start := rng_int(&rng, 0, 3)
		xs := [4]f32{r.x0 + ROOF_LIGHT_INSET, r.x1 - ROOF_LIGHT_INSET, r.x1 - ROOF_LIGHT_INSET, r.x0 + ROOF_LIGHT_INSET}
		zs := [4]f32{r.z0 + ROOF_LIGHT_INSET, r.z0 + ROOF_LIGHT_INSET, r.z1 - ROOF_LIGHT_INSET, r.z1 - ROOF_LIGHT_INSET}
		for j in 0 ..< k {
			m := (start + j) % 4
			c := Vec3{xs[m], top + ROOF_LIGHT_LIFT, zs[m]}
			blink := rng_f32(&rng) < ROOF_LIGHT_BLINK_CHANCE
			roof_light_add(&out, c, roof_light_tint(&rng), ROOF_LIGHT_WIDTH, blink, rng_f32(&rng), rng_range(&rng, BEACON_PERIOD_MIN, BEACON_PERIOD_MAX))
		}
	}
	return
}

// Warm white, amber, red or teal, weighted toward white. HDR: the shader adds a 1.6x core on top.
roof_light_tint :: proc(rng: ^Rng) -> [3]f32 {
	switch rng_int(rng, 0, 9) {
	case 0 ..= 4:
		return {1, 0.95, 0.85}
	case 5, 6:
		return {1, 0.6, 0.25}
	case 7, 8:
		return {1, 0.05, 0.03}
	case:
		return {0.2, 1, 0.7}
	}
}

// Steady red obstruction lights at the four corners of each lid (a ledge about every 40 stories).
supertall_warning_lights :: proc(out: ^Mesh_Builder, vs: []gfx.VertexData, stories: int) {
	n := supertall_tiers(stories)
	for i in 0 ..< n - 1 {
		top := f32(supertall_tier_end(stories, n, i) + SUPERTALL_LID)
		r := bounds_at(vs, top)
		if r.x1 < r.x0 do continue
		for x in ([2]f32{r.x0 + ROOF_LIGHT_INSET, r.x1 - ROOF_LIGHT_INSET}) {
			for z in ([2]f32{r.z0 + ROOF_LIGHT_INSET, r.z1 - ROOF_LIGHT_INSET}) {
				roof_light_add(out, Vec3{x, top + ROOF_LIGHT_LIFT, z}, {1, 0.05, 0.03}, ROOF_LIGHT_WIDTH, false, 0, 1)
			}
		}
	}
}

highest_y :: proc(vs: []gfx.VertexData) -> f32 {
	y: f32 = -math.F32_MAX
	for v in vs do y = max(y, v.position.y)
	return y
}

// XZ bounds of the vertices at height y. Empty (x1 < x0) if there are none.
bounds_at :: proc(vs: []gfx.VertexData, y: f32) -> Rect {
	r := Rect{x0 = math.F32_MAX, x1 = -math.F32_MAX, z0 = math.F32_MAX, z1 = -math.F32_MAX}
	for v in vs do if abs(v.position.y - y) < 0.01 {
		r.x0 = min(r.x0, v.position.x)
		r.x1 = max(r.x1, v.position.x)
		r.z0 = min(r.z0, v.position.z)
		r.z1 = max(r.z1, v.position.z)
	}
	return r
}
