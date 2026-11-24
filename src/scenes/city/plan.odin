// City layout on the 1024 x 1024 plot grid (1 plot = 1 unit). Streets are claimed cells, not geometry: the city
// mesh draws them only in the dev view. Same seed, same plan.
package city

import "core:math"

CITY_SIZE :: 1024
CITY_CENTRE :: CITY_SIZE / 2
CITY_CELLS :: CITY_SIZE * CITY_SIZE
AVENUE_WIDTH :: 10
STREET_BLOCK_MIN :: 24
STREET_BLOCK_MAX :: 56
STREET_LANES_MIN :: 2 // road widths are even: 4, 6 or 8 units
STREET_LANES_MAX :: 4

CLAIM_FREE :: u8(0)
CLAIM_ROAD :: u8(1)
CLAIM_BUILDING :: u8(2)

SKYSCRAPER_COUNT :: 20
SKYSCRAPER_FOOTPRINT_MIN :: 18
SKYSCRAPER_FOOTPRINT_MAX :: 24
SKYSCRAPER_STORIES_MIN :: 45
SKYSCRAPER_STORIES_MAX :: 55
SKYSCRAPER_MARGIN :: 3
SKYSCRAPER_ZONE_MIN :: 256
SKYSCRAPER_ZONE_MAX :: 768

MEDIUM_COUNT :: 48
MEDIUM_FOOTPRINT_MIN :: 10
MEDIUM_FOOTPRINT_MAX :: 16
MEDIUM_STORIES_MIN :: 25
MEDIUM_STORIES_MAX :: 35
MEDIUM_MARGIN :: 2
MEDIUM_ZONE_MIN :: 128
MEDIUM_ZONE_MAX :: 896

SMALL_FOOTPRINT_MIN :: 6
SMALL_FOOTPRINT_MAX :: 14
SMALL_STORIES_MIN :: 4
SMALL_STORIES_MAX :: 22
SMALL_MARGIN :: 1
SMALL_FADE_RADIUS :: 724 // stories fall from SMALL_STORIES_MAX at the centre to the minimum at this distance

PLACE_TRIES :: 200

Building_Kind :: enum u8 {
	Cube,
	Blocky,
	Modern,
	Classic,
}

Tier :: enum u8 {
	Skyscraper,
	Medium,
	Small,
}

// Min corner and size in plot units; the footprint covers [x, x+w) x [z, z+d).
Plot :: struct {
	kind:    Building_Kind,
	tier:    Tier,
	x, z:    i32,
	w, d:    i32,
	stories: i32,
}

// Half-open XZ rect in plot units.
Road_Rect :: struct {
	x0, z0, x1, z1: i32,
}

Plan :: struct {
	claimed:   []u8, // CITY_CELLS, row-major by z: CLAIM_FREE, CLAIM_ROAD or CLAIM_BUILDING
	buildings: [dynamic]Plot,
	roads:     [dynamic]Road_Rect,
}

plan_destroy :: proc(p: ^Plan) {
	delete(p.claimed)
	delete(p.buildings)
	delete(p.roads)
	p^ = {}
}

plan_build :: proc(seed: u32) -> Plan {
	p := Plan {
		claimed = make([]u8, CITY_CELLS),
	}
	rng := rng_seed(seed)
	plan_streets(&p, &rng)
	for _ in 0 ..< SKYSCRAPER_COUNT {
		plot := Plot {
			kind    = Building_Kind(rng_int(&rng, 1, 3)),
			tier    = .Skyscraper,
			w       = i32(rng_int(&rng, SKYSCRAPER_FOOTPRINT_MIN, SKYSCRAPER_FOOTPRINT_MAX)),
			d       = i32(rng_int(&rng, SKYSCRAPER_FOOTPRINT_MIN, SKYSCRAPER_FOOTPRINT_MAX)),
			stories = i32(rng_int(&rng, SKYSCRAPER_STORIES_MIN, SKYSCRAPER_STORIES_MAX)),
		}
		plan_place_random(&p, &rng, plot, SKYSCRAPER_ZONE_MIN, SKYSCRAPER_ZONE_MAX, SKYSCRAPER_MARGIN)
	}
	for _ in 0 ..< MEDIUM_COUNT {
		plot := Plot {
			kind    = Building_Kind(rng_int(&rng, 0, 3)),
			tier    = .Medium,
			w       = i32(rng_int(&rng, MEDIUM_FOOTPRINT_MIN, MEDIUM_FOOTPRINT_MAX)),
			d       = i32(rng_int(&rng, MEDIUM_FOOTPRINT_MIN, MEDIUM_FOOTPRINT_MAX)),
			stories = i32(rng_int(&rng, MEDIUM_STORIES_MIN, MEDIUM_STORIES_MAX)),
		}
		plan_place_random(&p, &rng, plot, MEDIUM_ZONE_MIN, MEDIUM_ZONE_MAX, MEDIUM_MARGIN)
	}
	plan_fill_small(&p, &rng)
	return p
}

// Centre avenue, then blocks and streets out to both edges. Intervals are [lo, hi) along one axis.
plan_axis_streets :: proc(rng: ^Rng, out: ^[dynamic][2]i32) {
	half := i32(AVENUE_WIDTH / 2)
	append(out, [2]i32{CITY_CENTRE - half, CITY_CENTRE + half})
	pos := i32(CITY_CENTRE + half)
	for {
		pos += i32(rng_int(rng, STREET_BLOCK_MIN, STREET_BLOCK_MAX))
		if pos >= CITY_SIZE do break
		end := min(pos + i32(2 * rng_int(rng, STREET_LANES_MIN, STREET_LANES_MAX)), CITY_SIZE)
		append(out, [2]i32{pos, end})
		pos = end
	}
	pos = CITY_CENTRE - half
	for {
		pos -= i32(rng_int(rng, STREET_BLOCK_MIN, STREET_BLOCK_MAX))
		if pos <= 0 do break
		start := max(pos - i32(2 * rng_int(rng, STREET_LANES_MIN, STREET_LANES_MAX)), 0)
		append(out, [2]i32{start, pos})
		pos = start
	}
}

plan_streets :: proc(p: ^Plan, rng: ^Rng) {
	xs, zs: [dynamic][2]i32
	defer delete(xs)
	defer delete(zs)
	plan_axis_streets(rng, &xs)
	plan_axis_streets(rng, &zs)
	for s in xs do append(&p.roads, Road_Rect{x0 = s[0], z0 = 0, x1 = s[1], z1 = CITY_SIZE})
	for s in zs do append(&p.roads, Road_Rect{x0 = 0, z0 = s[0], x1 = CITY_SIZE, z1 = s[1]})
	for r in p.roads {
		for z in r.z0 ..< r.z1 {
			for x in r.x0 ..< r.x1 do p.claimed[z * CITY_SIZE + x] = CLAIM_ROAD
		}
	}
}

// Claims the footprint if every cell is free and inside the city. The margin claims only free cells, so
// later plots keep the gap and never reach into roads.
plan_try_place :: proc(p: ^Plan, x, z, w, d, margin: i32) -> bool {
	if x < 0 || z < 0 || x + w > CITY_SIZE || z + d > CITY_SIZE do return false
	for zz in z ..< z + d {
		for xx in x ..< x + w do if p.claimed[zz * CITY_SIZE + xx] != CLAIM_FREE do return false
	}
	for zz in max(z - margin, 0) ..< min(z + d + margin, CITY_SIZE) {
		for xx in max(x - margin, 0) ..< min(x + w + margin, CITY_SIZE) {
			i := zz * CITY_SIZE + xx
			if p.claimed[i] == CLAIM_FREE do p.claimed[i] = CLAIM_BUILDING
		}
	}
	return true
}

// Random min corners inside [lo, hi) until one fits; the plot is dropped after PLACE_TRIES misses.
plan_place_random :: proc(p: ^Plan, rng: ^Rng, plot: Plot, lo, hi, margin: i32) -> bool {
	for _ in 0 ..< PLACE_TRIES {
		x := i32(rng_int(rng, int(lo), int(hi - plot.w)))
		z := i32(rng_int(rng, int(lo), int(hi - plot.d)))
		if !plan_try_place(p, x, z, plot.w, plot.d, margin) do continue
		placed := plot
		placed.x = x
		placed.z = z
		append(&p.buildings, placed)
		return true
	}
	return false
}

// Every cell in shuffled order is a candidate min corner for a random cube footprint. Shuffled so the packing
// has no scan-order bias.
plan_fill_small :: proc(p: ^Plan, rng: ^Rng) {
	order := make([]i32, CITY_CELLS)
	defer delete(order)
	for i in 0 ..< CITY_CELLS do order[i] = i32(i)
	for i := CITY_CELLS - 1; i > 0; i -= 1 {
		j := rng_int(rng, 0, i)
		order[i], order[j] = order[j], order[i]
	}
	for cell in order {
		if p.claimed[cell] != CLAIM_FREE do continue
		x := cell % CITY_SIZE
		z := cell / CITY_SIZE
		w := i32(rng_int(rng, SMALL_FOOTPRINT_MIN, SMALL_FOOTPRINT_MAX))
		d := i32(rng_int(rng, SMALL_FOOTPRINT_MIN, SMALL_FOOTPRINT_MAX))
		if !plan_try_place(p, x, z, w, d, SMALL_MARGIN) do continue
		append(&p.buildings, Plot{kind = .Cube, tier = .Small, x = x, z = z, w = w, d = d, stories = small_stories(rng, x, z, w, d)})
	}
}

// Upper bound falls linearly from SMALL_STORIES_MAX at the city centre to SMALL_STORIES_MIN at SMALL_FADE_RADIUS.
small_stories :: proc(rng: ^Rng, x, z, w, d: i32) -> i32 {
	dx := f32(x) + f32(w) / 2 - CITY_CENTRE
	dz := f32(z) + f32(d) / 2 - CITY_CENTRE
	dist := math.sqrt(dx * dx + dz * dz)
	top := max(SMALL_STORIES_MIN, int(f32(SMALL_STORIES_MAX) * (1 - dist / SMALL_FADE_RADIUS)))
	return i32(rng_int(rng, SMALL_STORIES_MIN, top))
}
