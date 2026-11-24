// CPU building generators. Each appends one building to a Mesh_Builder.
// Units: 1 unit = 1 window. A wall w wide and h stories tall spans (w/TILE_WINDOWS, h/TILE_WINDOWS) uv in its tile;
// uv may run past 1 and the shader wraps it inside the tile.
package city

import "core:math"
import "core:math/linalg"

BUILDING_ROOF :: [4]f32{0, 0, 0, 1} // roofs and spikes are black: the shader multiplies by vertex colour
building_tints := [4][4]f32{{1, 0.94, 0.8, 1}, {1, 0.9, 0.45, 1}, {0.72, 0.85, 1, 1}, {1, 1, 1, 1}} // warm white, yellow, pale blue, white
BLOCKY_RECT_TRIES :: 16
MODERN_SECTOR :: 9 // segments per 90 degrees
MODERN_SEGMENTS :: 36 // 10 degrees each
TOWER_MIN_WIDTH :: 6 // taper never narrows a tier below this
CLUTTER_SCALE :: 0.5 // modern clutter stays inside this share of the ellipse's bounding box (cut sectors chord inward)

Building_Proc :: proc(b: ^Mesh_Builder, rng: ^Rng, origin: Vec3, footprint: [2]f32, stories: int)

// Per-building appearance: wall tint, atlas tile (0..TILE_COUNT-1) and offset inside the tile (a multiple of
// 1/TILE_WINDOWS, so window borders stay aligned).
Facade :: struct {
	color: [4]f32,
	tile:  u8,
	uv:    [2]f32,
}

// Axis-aligned XZ rectangle in world units.
Rect :: struct {
	x0, x1, z0, z1: f32,
}

WINDOW_UV :: 1.0 / TILE_WINDOWS

building_facade :: proc(rng: ^Rng) -> Facade {
	return {
		color = building_tints[rng_int(rng, 0, len(building_tints) - 1)],
		tile = u8(rng_int(rng, 0, TILE_COUNT - 1)),
		uv = {f32(rng_int(rng, 0, TILE_WINDOWS - 1)) * WINDOW_UV, f32(rng_int(rng, 0, TILE_WINDOWS - 1)) * WINDOW_UV},
	}
}

centred_rect :: proc(c: [2]f32, half: [2]f32) -> Rect {
	return {x0 = c.x - half.x, x1 = c.x + half.x, z0 = c.y - half.y, z1 = c.y + half.y}
}

// Distance of each side from c: +X, -X, +Z, -Z.
rect_reach :: proc(r: Rect, c: [2]f32) -> [4]f32 {
	return {r.x1 - c.x, c.x - r.x0, r.z1 - c.y, c.y - r.z0}
}

// Side i as its XZ endpoints (a, c) in wall order: wall(a, c) faces outward. Sides: +Z, -Z, +X, -X.
rect_side :: proc(r: Rect, i: int) -> (a, c: [2]f32) {
	switch i {
	case 0:
		return {r.x0, r.z1}, {r.x1, r.z1}
	case 1:
		return {r.x1, r.z0}, {r.x0, r.z0}
	case 2:
		return {r.x1, r.z1}, {r.x1, r.z0}
	}
	return {r.x0, r.z0}, {r.x0, r.z1}
}

// Vertical wall from a to c (XZ), y0..y1. Normal is cross(c - a, up): outward for the wall orders above.
// u is the uv x at a; returns the uv x at c, so the caller can run u on around a corner.
building_wall :: proc(b: ^Mesh_Builder, f: Facade, a, c: [2]f32, y0, y1: f32, u: f32) -> f32 {
	w := linalg.length(c - a)
	color := f.color
	color.a = (f32(f.tile) + 0.5) / TILE_COUNT // tile index, decoded in shaders/city.slang
	builder_quad(
		b,
		{a.x, y0, a.y},
		{c.x, y0, c.y},
		{c.x, y1, c.y},
		{a.x, y1, a.y},
		{u, f.uv.y},
		{u + w * WINDOW_UV, f.uv.y + (y1 - y0) * WINDOW_UV},
		color,
	)
	return u + w * WINDOW_UV
}

building_roof :: proc(b: ^Mesh_Builder, r: Rect, y: f32) {
	builder_quad(b, {r.x0, y, r.z0}, {r.x0, y, r.z1}, {r.x1, y, r.z1}, {r.x1, y, r.z0}, {}, {}, BUILDING_ROOF)
}

// Four walls and a black top: a box with no bottom face. Each wall starts one window back from the previous wall's
// end, so the corner column is shared and the texture runs on around the corner instead of mirroring.
building_block :: proc(b: ^Mesh_Builder, f: Facade, r: Rect, y0, y1: f32) {
	u := f.uv.x
	for i in 0 ..< 4 {
		a, c := rect_side(r, i)
		u = building_wall(b, f, a, c, y0, y1, u) - WINDOW_UV
	}
	building_roof(b, r, y1)
}

// Random rect around c containing it (sides at least a quarter of the half size), rounded to whole windows.
random_rect :: proc(rng: ^Rng, c: [2]f32, half: [2]f32) -> Rect {
	return {
		x0 = c.x - math.round(rng_range(rng, 0.25, 1) * half.x),
		x1 = c.x + math.round(rng_range(rng, 0.25, 1) * half.x),
		z0 = c.y - math.round(rng_range(rng, 0.25, 1) * half.y),
		z1 = c.y + math.round(rng_range(rng, 0.25, 1) * half.y),
	}
}

building_cube :: proc(b: ^Mesh_Builder, rng: ^Rng, origin: Vec3, footprint: [2]f32, stories: int) {
	f := building_facade(rng)
	r := centred_rect(origin.xz, footprint / 2)
	top := origin.y + f32(stories)
	building_block(b, f, r, origin.y, top)
	roof_clutter(b, rng, r, top)
}

// Stepped tiers: each tier is a random rect around the centre, lower than the one before, and reaches past every
// earlier tier on at least one side (else it is hidden).
building_blocky :: proc(b: ^Mesh_Builder, rng: ^Rng, origin: Vec3, footprint: [2]f32, stories: int) {
	f := building_facade(rng)
	c := origin.xz
	half := footprint / 2
	first := random_rect(rng, c, half)
	building_block(b, f, first, origin.y, origin.y + f32(stories))
	roof_clutter(b, rng, first, origin.y + f32(stories)) // tallest tier only
	best := rect_reach(first, c)
	top := stories
	for _ in 1 ..< rng_int(rng, 2, 5) {
		if top < 2 do break
		next, ok := blocky_next_tier(rng, c, half, best)
		if !ok do break
		h := rng_int(rng, max(1, top / 2), top - 1)
		building_block(b, f, next, origin.y, origin.y + f32(h))
		top = h
		reach := rect_reach(next, c)
		for i in 0 ..< 4 do best[i] = max(best[i], reach[i])
	}
}

blocky_next_tier :: proc(rng: ^Rng, c, half: [2]f32, best: [4]f32) -> (r: Rect, ok: bool) {
	for _ in 0 ..< BLOCKY_RECT_TRIES {
		r = random_rect(rng, c, half)
		reach := rect_reach(r, c)
		for i in 0 ..< 4 do if reach[i] > best[i] do return r, true
	}
	return {}, false
}

// Cylinder as a 36-gon stretched to the footprint. Up to three 90-degree sectors are cut: the outline jumps
// the sector with one flat wall, so the cut shows as a flat face.
building_modern :: proc(b: ^Mesh_Builder, rng: ^Rng, origin: Vec3, footprint: [2]f32, stories: int) {
	f := building_facade(rng)
	top := origin.y + f32(stories)
	half := footprint / 2
	cut: [4]bool
	for n := rng_int(rng, 0, 3); n > 0; {
		s := rng_int(rng, 0, 3)
		if !cut[s] {
			cut[s] = true
			n -= 1
		}
	}
	phase := rng_range(rng, 0, math.TAU)
	ring: [MODERN_SEGMENTS][2]f32 // CCW seen from above
	count := 0
	for i in 0 ..< MODERN_SEGMENTS {
		if cut[i / MODERN_SECTOR] && i % MODERN_SECTOR != 0 do continue
		a := phase + f32(i) * math.TAU / MODERN_SEGMENTS
		ring[count] = origin.xz + {half.x * math.cos(a), half.y * math.sin(a)}
		count += 1
	}
	centre := Vec3{origin.x, top, origin.z}
	u := f.uv.x
	for k in 0 ..< count {
		next := ring[(k + 1) % count]
		u = building_wall(b, f, next, ring[k], origin.y, top, u)
		builder_tri(b, {next.x, top, next.y}, {ring[k].x, top, ring[k].y}, centre, BUILDING_ROOF)
	}
	roof_clutter(b, rng, centred_rect(origin.xz, half * CLUTTER_SCALE), top)
}

// Per-building tower style, rolled once. Windowed walls are split into 1-unit columns: a column is a window, a
// black stripe, or a black corner.
Tower_Style :: struct {
	corners: bool, // black column at each end of a windowed wall
	group:   int, // window columns per group; 0 = no stripes
	stripe:  int, // black columns between groups
}

// Tiers stack on lids: each tier takes 1/share of the remaining height (last tier takes the rest), each lid is
// 1..3 stories black with a ledge of 0 or 1 unit, and tiers above a lid start with 0..2 blank stories.
building_tower :: proc(b: ^Mesh_Builder, rng: ^Rng, origin: Vec3, footprint: [2]f32, stories: int) {
	f := building_facade(rng)
	black := f
	black.color = BUILDING_ROOF
	c := origin.xz
	rect := centred_rect(c, footprint / 2)
	share := rng_int(rng, 2, 4)
	style := Tower_Style{corners = rng_int(rng, 0, 1) == 1}
	if rng_int(rng, 0, 2) > 0 {
		style.group = rng_int(rng, 2, 6)
		style.stripe = rng_int(rng, 1, 2)
	}
	taper := rng_int(rng, 0, 1) == 1
	ledge := f32(rng_int(rng, 0, 1))
	y := origin.y
	rem := stories
	for {
		h := max(1, rem / share)
		if rem - h < 2 do h = rem // no room for a lid and another tier: this tier takes the rest
		blank := 0
		if y > origin.y do blank = min(rng_int(rng, 0, 2), h - 1)
		if blank > 0 do tower_walls(b, black, rect, y, y + f32(blank), {})
		tower_walls(b, f, rect, y + f32(blank), y + f32(h), style)
		y += f32(h)
		rem -= h
		if rem == 0 {
			building_roof(b, rect, y)
			roof_clutter(b, rng, rect, y)
			break
		}
		lid_height := min(rng_int(rng, 1, 3), rem - 1)
		lid := rect_grow(rect, ledge)
		building_block(b, black, lid, y, y + f32(lid_height))
		y += f32(lid_height)
		rem -= lid_height
		roof_clutter(b, rng, lid, y)
		if taper do rect = tower_taper(rng, rect)
	}
	if rng_int(rng, 0, 1) == 1 { // antenna: 1 unit wide, 4..8 stories, on half the towers
		ax, az := math.floor(c.x), math.floor(c.y)
		building_block(b, black, Rect{x0 = ax, x1 = ax + 1, z0 = az, z1 = az + 1}, y, y + f32(rng_int(rng, 4, 8)))
	}
}

// Four walls of r, columns as in style.
tower_walls :: proc(b: ^Mesh_Builder, f: Facade, r: Rect, y0, y1: f32, s: Tower_Style) {
	u := f.uv.x
	for i in 0 ..< 4 {
		a, c := rect_side(r, i)
		u = building_wall_columns(b, f, a, c, y0, y1, u, s) - WINDOW_UV
	}
}

// Wall a to c as runs of 1-unit columns. Black runs are the same quads in black, and u advances through them too,
// so the window grid stays aligned. Returns the uv x at c. Wall lengths are whole units.
building_wall_columns :: proc(b: ^Mesh_Builder, f: Facade, a, c: [2]f32, y0, y1: f32, u: f32, s: Tower_Style) -> f32 {
	n := int(linalg.length(c - a) + 0.5)
	step := (c - a) / f32(n)
	i0 := 0
	for i0 < n {
		dark := tower_column_dark(s, i0, n)
		i1 := i0 + 1
		for i1 < n && tower_column_dark(s, i1, n) == dark do i1 += 1
		g := f
		if dark do g.color = BUILDING_ROOF
		building_wall(b, g, a + step * f32(i0), a + step * f32(i1), y0, y1, u + f32(i0) * WINDOW_UV)
		i0 = i1
	}
	return u + f32(n) * WINDOW_UV
}

tower_column_dark :: proc(s: Tower_Style, i, n: int) -> bool {
	if s.corners && (i == 0 || i == n - 1) do return true
	return s.group > 0 && i % (s.group + s.stripe) >= s.group
}

// Each side in by 1..2 units, if the tier stays at least TOWER_MIN_WIDTH wide on that axis.
tower_taper :: proc(rng: ^Rng, r: Rect) -> Rect {
	k := f32(rng_int(rng, 1, 2))
	out := r
	if r.x1 - r.x0 - 2 * k >= TOWER_MIN_WIDTH {
		out.x0 += k
		out.x1 -= k
	}
	if r.z1 - r.z0 - 2 * k >= TOWER_MIN_WIDTH {
		out.z0 += k
		out.z1 -= k
	}
	return out
}

rect_grow :: proc(r: Rect, e: f32) -> Rect {
	return {x0 = r.x0 - e, x1 = r.x1 + e, z0 = r.z0 - e, z1 = r.z1 + e}
}

// 1..4 black boxes (HVAC) on a roof at height y: 1..3 x 1..3 units, 1..2 high.
roof_clutter :: proc(b: ^Mesh_Builder, rng: ^Rng, r: Rect, y: f32) {
	black := Facade{color = BUILDING_ROOF}
	for _ in 0 ..< rng_int(rng, 1, 4) {
		x0, x1, okx := clutter_span(rng, r.x0, r.x1, rng_int(rng, 1, 3))
		z0, z1, okz := clutter_span(rng, r.z0, r.z1, rng_int(rng, 1, 3))
		if !okx || !okz do continue
		building_block(b, black, Rect{x0 = x0, x1 = x1, z0 = z0, z1 = z1}, y, y + f32(rng_int(rng, 1, 2)))
	}
}

// A run of up to want whole units inside [lo, hi), one unit in from each end when the roof is wider than 4.
clutter_span :: proc(rng: ^Rng, lo, hi: f32, want: int) -> (p0, p1: f32, ok: bool) {
	m: f32 = 1 if hi - lo > 4 else 0
	from := math.ceil(lo + m)
	avail := int(math.floor(hi - m) - from)
	if avail < 1 do return 0, 0, false
	size := min(want, avail)
	p0 = from + f32(rng_int(rng, 0, avail - size))
	return p0, p0 + f32(size), true
}
