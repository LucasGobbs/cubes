// City layout on the 3072 x 2048 plot grid (1 plot = 1 unit). Streets are claimed cells, not geometry: the city
// mesh draws them only in the dev view. Same seed, same plan.
package city

import "core:math"
import "core:slice"

CITY_W :: 3072 // x; shaders/city_ground_gen.slang and city_cars.slang repeat the sizes: keep equal
CITY_D :: 2048 // z
CITY_CENTRE_X :: CITY_W / 2
CITY_CENTRE_Z :: CITY_D / 2
CITY_CELLS :: CITY_W * CITY_D
AVENUE_WIDTH :: 10
STREET_BLOCK_MIN :: 24
STREET_BLOCK_MAX :: 56
DOUBLE_BLOCK_CHANCE :: 0.2 // a double block: 56..112 with no street between two blocks
DOUBLE_BLOCK_MAX :: 112
PLAZA_BLOCK_CHANCE :: 0.06
PLAZA_BLOCK_MIN :: 100
PLAZA_BLOCK_MAX :: 140
STREET_LANES_MIN :: 2 // road widths are even: 4, 6 or 8 units
STREET_LANES_MAX :: 4
BIG_BLOCK_AREA :: 4000 // above a normal block's 56 x 56: gets one large plot or a park
PARK_CHANCE :: 0.02 // share of big blocks left dark and empty
ZONE_EDGE :: 256 // skyscrapers and mediums stay this far from the city edge

CLAIM_FREE :: u8(0)
CLAIM_ROAD :: u8(1)
CLAIM_BUILDING :: u8(2)
CLAIM_PARK :: u8(3) // empty park: not road, not built, dark ground

PLACE_TRIES :: 200
SMALL_MARGIN :: 2
SMALL_FOOTPRINT_MIN :: 6
SMALL_FOOTPRINT_MAX :: 14

DENSITY_CELL_LARGE :: 160 // value-noise cell sizes: cluster scale, then two finer octaves
DENSITY_CELL_MID :: 80
DENSITY_CELL_FINE :: 40
DENSITY_CENTRE_RADIUS :: 1280 // the centre falloff reaches zero at this distance
OUTLIER_CHANCE :: 0.05 // share of buildings that are 1.6x taller than their roll (capped at the tier maximum)
OUTLIER_SCALE :: 1.6
WAREHOUSE_EDGE :: 0.6 * CITY_CENTRE_Z // small plots beyond this distance from the centre may be warehouses

Building_Kind :: enum u8 {
	Cube,
	Blocky,
	Modern,
	Tower,
	Stepped,
	Slab,
	Twin,
	LShape,
	Warehouse,
}

Tier :: enum u8 {
	Skyscraper,
	Medium,
	Small,
}

Tier_Rules :: struct {
	count:         int,
	footprint_min: i32,
	footprint_max: i32,
	stories_min:   int,
	stories_max:   int,
	margin:        i32,
}

// Skyscrapers may be placed anywhere in the zone, weighted by downtown density (they cluster on the peaks).
tier_rules := [Tier]Tier_Rules {
	.Skyscraper = {count = 180, footprint_min = 18, footprint_max = 24, stories_min = 55, stories_max = 110, margin = 4},
	.Medium     = {count = 300, footprint_min = 10, footprint_max = 16, stories_min = 20, stories_max = 60, margin = 3},
	.Small      = {footprint_min = SMALL_FOOTPRINT_MIN, footprint_max = SMALL_FOOTPRINT_MAX, stories_min = 3, stories_max = 40, margin = SMALL_MARGIN},
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
	blocks: [dynamic]Road_Rect
	defer delete(blocks)
	plan_streets(&p, &rng, &blocks)
	plan_big_blocks(&p, &rng, seed, blocks[:])
	for tier in Tier.Skyscraper ..= Tier.Medium {
		for _ in 0 ..< tier_rules[tier].count do plan_place_tier(&p, &rng, seed, tier)
	}
	plan_fill_small(&p, &rng, seed)
	return p
}

// Block length along one axis: mostly normal, sometimes a double block (no street between two blocks), rarely a plaza.
plan_block_length :: proc(rng: ^Rng) -> i32 {
	roll := rng_f32(rng)
	if roll < PLAZA_BLOCK_CHANCE do return i32(rng_int(rng, PLAZA_BLOCK_MIN, PLAZA_BLOCK_MAX))
	if roll < PLAZA_BLOCK_CHANCE + DOUBLE_BLOCK_CHANCE do return i32(rng_int(rng, STREET_BLOCK_MAX, DOUBLE_BLOCK_MAX))
	return i32(rng_int(rng, STREET_BLOCK_MIN, STREET_BLOCK_MAX))
}

// Centre avenue, then blocks and streets out to both edges. Intervals are [lo, hi) along one axis.
plan_axis_streets :: proc(rng: ^Rng, length: i32, out: ^[dynamic][2]i32) {
	half := i32(AVENUE_WIDTH / 2)
	centre := length / 2
	append(out, [2]i32{centre - half, centre + half})
	pos := centre + half
	for {
		pos += plan_block_length(rng)
		if pos >= length do break
		end := min(pos + i32(2 * rng_int(rng, STREET_LANES_MIN, STREET_LANES_MAX)), length)
		append(out, [2]i32{pos, end})
		pos = end
	}
	pos = centre - half
	for {
		pos -= plan_block_length(rng)
		if pos <= 0 do break
		start := max(pos - i32(2 * rng_int(rng, STREET_LANES_MIN, STREET_LANES_MAX)), 0)
		append(out, [2]i32{start, pos})
		pos = start
	}
}

// Blocks along one axis: the intervals of [0, length) that no street covers.
plan_axis_gaps :: proc(streets: [][2]i32, length: i32, out: ^[dynamic][2]i32) {
	slice.sort_by(streets, proc(a, b: [2]i32) -> bool { return a[0] < b[0] })
	pos := i32(0)
	for s in streets {
		if s[0] > pos do append(out, [2]i32{pos, s[0]})
		pos = s[1]
	}
	if pos < length do append(out, [2]i32{pos, length})
}

// Roads run edge to edge: x streets span the depth, z streets the width. Blocks are the cells between them.
plan_streets :: proc(p: ^Plan, rng: ^Rng, blocks: ^[dynamic]Road_Rect) {
	xs, zs: [dynamic][2]i32
	defer delete(xs)
	defer delete(zs)
	plan_axis_streets(rng, CITY_W, &xs)
	plan_axis_streets(rng, CITY_D, &zs)
	for s in xs do append(&p.roads, Road_Rect{x0 = s[0], z0 = 0, x1 = s[1], z1 = CITY_D})
	for s in zs do append(&p.roads, Road_Rect{x0 = 0, z0 = s[0], x1 = CITY_W, z1 = s[1]})
	for r in p.roads {
		for z in r.z0 ..< r.z1 {
			for x in r.x0 ..< r.x1 do p.claimed[z * CITY_W + x] = CLAIM_ROAD
		}
	}
	xgaps, zgaps: [dynamic][2]i32
	defer delete(xgaps)
	defer delete(zgaps)
	plan_axis_gaps(xs[:], CITY_W, &xgaps)
	plan_axis_gaps(zs[:], CITY_D, &zgaps)
	for xg in xgaps do for zg in zgaps do append(blocks, Road_Rect{x0 = xg[0], z0 = zg[0], x1 = xg[1], z1 = zg[1]})
}

// Big blocks (double blocks, plazas) get one large plot, or stay dark as a park. Runs before the tiers so the plot finds free cells.
plan_big_blocks :: proc(p: ^Plan, rng: ^Rng, seed: u32, blocks: []Road_Rect) {
	for b in blocks {
		w, d := b.x1 - b.x0, b.z1 - b.z0
		if w * d <= BIG_BLOCK_AREA do continue
		if rng_f32(rng) < PARK_CHANCE {
			for z in b.z0 ..< b.z1 do for x in b.x0 ..< b.x1 do p.claimed[z * CITY_W + x] = CLAIM_PARK
			continue
		}
		tier := Tier.Skyscraper if rng_f32(rng) < 0.5 else Tier.Medium
		m := tier_rules[tier].margin
		if w - 2 * m < w * 3 / 5 || d - 2 * m < d * 3 / 5 do continue
		pw := i32(rng_int(rng, int(w * 3 / 5), int(w - 2 * m)))
		pd := i32(rng_int(rng, int(d * 3 / 5), int(d - 2 * m)))
		x := b.x0 + m + i32(rng_int(rng, 0, int(w - 2 * m - pw)))
		z := b.z0 + m + i32(rng_int(rng, 0, int(d - 2 * m - pd)))
		if !plan_try_place(p, x, z, pw, pd, m) do continue
		plot := Plot{tier = tier, x = x, z = z, w = pw, d = pd}
		plan_finish_plot(rng, &plot, plan_density(seed, f32(x) + f32(pw) / 2, f32(z) + f32(pd) / 2))
		append(&p.buildings, plot)
	}
}

// Claims the footprint if every cell is free and inside the city. The margin claims only free cells, so
// later plots keep the gap and never reach into roads.
plan_try_place :: proc(p: ^Plan, x, z, w, d, margin: i32) -> bool {
	if x < 0 || z < 0 || x + w > CITY_W || z + d > CITY_D do return false
	for zz in z ..< z + d {
		for xx in x ..< x + w do if p.claimed[zz * CITY_W + xx] != CLAIM_FREE do return false
	}
	for zz in max(z - margin, 0) ..< min(z + d + margin, CITY_D) {
		for xx in max(x - margin, 0) ..< min(x + w + margin, CITY_W) {
			i := zz * CITY_W + xx
			if p.claimed[i] == CLAIM_FREE do p.claimed[i] = CLAIM_BUILDING
		}
	}
	return true
}

// Random footprint and min corner in the tier's zone until one fits; the plot is dropped after PLACE_TRIES misses.
plan_place_tier :: proc(p: ^Plan, rng: ^Rng, seed: u32, tier: Tier) {
	rules := tier_rules[tier]
	for _ in 0 ..< PLACE_TRIES {
		w := i32(rng_int(rng, int(rules.footprint_min), int(rules.footprint_max)))
		d := i32(rng_int(rng, int(rules.footprint_min), int(rules.footprint_max)))
		x := i32(rng_int(rng, ZONE_EDGE, CITY_W - ZONE_EDGE - int(w)))
		z := i32(rng_int(rng, ZONE_EDGE, CITY_D - ZONE_EDGE - int(d)))
		density := plan_density(seed, f32(x) + f32(w) / 2, f32(z) + f32(d) / 2)
		if tier == .Skyscraper && rng_f32(rng) > density * density do continue
		if !plan_try_place(p, x, z, w, d, rules.margin) do continue
		plot := Plot{tier = tier, x = x, z = z, w = w, d = d}
		plan_finish_plot(rng, &plot, density)
		append(&p.buildings, plot)
		return
	}
}

// Every cell in shuffled order is a candidate min corner for a random cube footprint. Shuffled so the packing
// has no scan-order bias.
plan_fill_small :: proc(p: ^Plan, rng: ^Rng, seed: u32) {
	order := make([]i32, CITY_CELLS)
	defer delete(order)
	for i in 0 ..< CITY_CELLS do order[i] = i32(i)
	for i := CITY_CELLS - 1; i > 0; i -= 1 {
		j := rng_int(rng, 0, i)
		order[i], order[j] = order[j], order[i]
	}
	rules := tier_rules[Tier.Small]
	for cell in order {
		if p.claimed[cell] != CLAIM_FREE do continue
		x := cell % CITY_W
		z := cell / CITY_W
		w := i32(rng_int(rng, int(rules.footprint_min), int(rules.footprint_max)))
		d := i32(rng_int(rng, int(rules.footprint_min), int(rules.footprint_max)))
		if !plan_try_place(p, x, z, w, d, rules.margin) do continue
		density := plan_density(seed, f32(x) + f32(w) / 2, f32(z) + f32(d) / 2)
		plot := Plot{tier = .Small, x = x, z = z, w = w, d = d}
		plan_finish_plot(rng, &plot, density)
		append(&p.buildings, plot)
	}
}

// Kind and stories for a placed plot. Warehouses are short and only come from small plots at the edge.
plan_finish_plot :: proc(rng: ^Rng, plot: ^Plot, density: f32) {
	cx := f32(plot.x) + f32(plot.w) / 2
	cz := f32(plot.z) + f32(plot.d) / 2
	plot.kind = plan_kind(rng, plot.tier, plan_centre_distance(cx, cz) > WAREHOUSE_EDGE)
	if plot.kind == .Warehouse {
		plot.stories = i32(rng_int(rng, 2, 5))
		return
	}
	rules := tier_rules[plot.tier]
	// Density sets the top of the roll, so most of a cluster is tall and the fringe stays low (not all 3s).
	top := rules.stories_min + int(f32(rules.stories_max - rules.stories_min) * (0.1 + 0.9 * density))
	n := rng_int(rng, rules.stories_min, top)
	if rng_f32(rng) < OUTLIER_CHANCE do n = int(f32(n) * OUTLIER_SCALE)
	plot.stories = i32(min(n, rules.stories_max))
}

// Weighted kind choice. Edge small plots are mostly cubes with some warehouses; the centre gets a mix.
plan_kind :: proc(rng: ^Rng, tier: Tier, edge: bool) -> Building_Kind {
	weights: [Building_Kind]int
	switch tier {
	case .Skyscraper:
		weights = #partial [Building_Kind]int{.Tower = 3, .Modern = 2, .Stepped = 2, .Slab = 2, .Twin = 2, .LShape = 1, .Blocky = 1}
	case .Medium:
		weights = #partial [Building_Kind]int{.Cube = 1, .Blocky = 2, .Modern = 2, .Tower = 2, .Stepped = 2, .Slab = 1, .Twin = 1, .LShape = 1}
	case .Small:
		if edge {
			weights = #partial [Building_Kind]int{.Cube = 7, .Warehouse = 3}
		} else {
			weights = #partial [Building_Kind]int{.Cube = 4, .Modern = 1, .Stepped = 2, .LShape = 2, .Slab = 1}
		}
	}
	total := 0
	for w in weights do total += w
	r := rng_int(rng, 0, total - 1)
	for k in Building_Kind {
		r -= weights[k]
		if r < 0 do return k
	}
	return .Cube
}

// Distance from the city centre, in plot units.
plan_centre_distance :: proc(x, z: f32) -> f32 {
	dx := x - CITY_CENTRE_X
	dz := z - CITY_CENTRE_Z
	return math.sqrt(dx * dx + dz * dz)
}

// Downtown density 0..1: value noise (three seeded octaves) gives local clusters, a falloff adds the centre.
plan_density :: proc(seed: u32, x, z: f32) -> f32 {
	n := 0.5 * value_noise(seed, x, z, DENSITY_CELL_LARGE) + 0.3 * value_noise(seed ~ 0x51ED27, x, z, DENSITY_CELL_MID) + 0.2 * value_noise(seed ~ 0xA3C59A, x, z, DENSITY_CELL_FINE)
	cluster := clamp((n - 0.4) * 3, 0, 1)
	centre := clamp(1 - plan_centre_distance(x, z) / DENSITY_CENTRE_RADIUS, 0, 1)
	return clamp(0.7 * cluster + 0.5 * centre, 0, 1)
}

// Smooth value noise in [0, 1): hashed lattice values, smoothstep-blended.
value_noise :: proc(seed: u32, x, z, cell: f32) -> f32 {
	gx := x / cell
	gz := z / cell
	fx := math.floor(gx)
	fz := math.floor(gz)
	tx := smoothstep01(gx - fx)
	tz := smoothstep01(gz - fz)
	ix := i32(fx)
	iz := i32(fz)
	a := lattice_hash(seed, ix, iz)
	b := lattice_hash(seed, ix + 1, iz)
	c := lattice_hash(seed, ix, iz + 1)
	d := lattice_hash(seed, ix + 1, iz + 1)
	return mix01(mix01(a, b, tx), mix01(c, d, tx), tz)
}

lattice_hash :: proc(seed: u32, x, z: i32) -> f32 {
	r := rng_seed(seed ~ (u32(x) * 0x27D4EB2D) ~ (u32(z) * 0x165667B1))
	rng_u32(&r) // first output of a near-zero xorshift state is weakly mixed
	return rng_f32(&r)
}

smoothstep01 :: proc(t: f32) -> f32 {
	return t * t * (3 - 2 * t)
}

mix01 :: proc(a, b, t: f32) -> f32 {
	return a + (b - a) * t
}
