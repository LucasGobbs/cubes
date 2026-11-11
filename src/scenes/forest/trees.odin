package forest

import "core:math"
import "core:math/linalg"
import gbbfx "../../gbbfx"

// Vertex counts per chunk (u16 index limit 65535; TREE_VERT_CAP guards the densest case).
// Typical (biome ~0.5, ~9 trees of mixed species, 3 rocks, 3 bushes): ~2.5k verts.
// Max: 17 oak/autumn trees x 424 + boulder cluster 144 + 3 rocks x 48 + 3 bushes x 48 ~ 7.9k.
TREE_VERT_CAP :: 60000
// Oak/autumn worst case: trunk 7 rings + 2 stubs x 2 rings + 7 blobs, rings x 8 sides.
TREE_MAX_VERTS :: 424

BLOB_SEGS :: 8
BLOB_RINGS :: 5
BLOB_VERTS :: (BLOB_RINGS + 1) * BLOB_SEGS
TREE_SIDES :: 8

TREE_MIN_SPACING :: 3.5
TREE_PROP_SPACING :: 2.0
// Canopy radius <= 3 m, so trees stay that far from chunk edges and never cross chunks.
TREE_EDGE_MARGIN :: 3.0
// Boulder clusters reach ~3.9 m with rock jitter.
BOULDER_EDGE_MARGIN :: 4.0
PROP_EDGE_MARGIN :: 1.5
TREE_ORIGIN_KEEP_OUT :: 8.0
TREE_MAX_SLOPE_Y :: 0.8
TREE_MAX_HEIGHT :: 45.0

TREE_BARK_OAK :: [3]f32{0.40, 0.27, 0.16}
TREE_BARK_PINE :: [3]f32{0.38, 0.26, 0.16}
TREE_BARK_BROAD :: [3]f32{0.45, 0.36, 0.28}
TREE_LEAF_OAK :: [3]f32{0.50, 0.72, 0.20}
TREE_LEAF_PINE :: [3]f32{0.16, 0.42, 0.28}
TREE_LEAF_BROAD :: [3]f32{0.22, 0.55, 0.20}
TREE_LEAF_AUTUMN :: [3][3]f32{{0.95, 0.55, 0.15}, {0.85, 0.35, 0.12}, {0.95, 0.80, 0.20}}
TREE_BUSH_LEAF :: [3]f32{0.30, 0.60, 0.18}
TREE_ROCK :: [3]f32{0.55, 0.54, 0.52}

Tree_Species :: enum {
	Oak,
	Autumn,
	Pine,
	Broad,
}

// One squashed sphere. crown_w > 0 blends normals toward `crown` (shared pivot so a whole
// canopy shades like one ball). uv.x = wind weight from wlo (0) to whi (1); wlo == whi => 0.
Tree_Blob :: struct {
	c, radii: [3]f32,
	color:    [3]f32,
	kind:     f32,
	crown:    [3]f32,
	crown_w:  f32,
	wlo, whi: f32,
	rough:    f32, // per-vertex radial jitter fraction (rocks)
	seed:     u32,
}

// Splitmix64 stream; seeded from chunk coords only, so placement is deterministic.
Tree_Rng :: struct {
	state: u64,
}

tree_rng_f32 :: proc(r: ^Tree_Rng) -> f32 {
	r.state += 0x9E3779B97F4A7C15
	z := r.state
	z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ~ (z >> 27)) * 0x94D049BB133111EB
	z ~= z >> 31
	return f32(z >> 40) / f32(1 << 24)
}

tree_rng_range :: proc(r: ^Tree_Rng, lo, hi: f32) -> f32 {
	return lo + (hi - lo) * tree_rng_f32(r)
}

tree_hash :: proc(a, b, c: u32) -> f32 {
	h := (a * 0x27d4eb2d) ~ (b * 0x165667b1) ~ (c * 0x9E3779B1)
	h ~= h >> 15
	h *= 0x2c1b3c6d
	h ~= h >> 12
	return f32(h) / 4294967295.0
}

trees_chunk :: proc(cx, cz: int, verts: ^[dynamic]gbbfx.VertexData, idx: ^[dynamic]u32) {
	x0, z0 := chunk_origin(cx, cz)
	rng := Tree_Rng{state = u64(cx * CHUNKS_PER_SIDE + cz) * 0x9E3779B97F4A7C15 + 1}
	biome := terrain_biome(x0 + CHUNK_SIZE / 2, z0 + CHUNK_SIZE / 2)

	placed := make([dynamic][2]f32, 0, 32)
	defer delete(placed)

	want := int(2 + 14 * biome + 0.5) + int(tree_rng_f32(&rng) * 3) - 1
	planted := 0
	for _ in 0 ..< 4 * want {
		if planted >= want do break
		p, ok := tree_find_spot(&rng, x0, z0, TREE_EDGE_MARGIN, TREE_MIN_SPACING, placed[:])
		if !ok do continue
		p_biome := terrain_biome(p.x, p.y)
		if p_biome < 0.15 && tree_rng_f32(&rng) < 0.75 do continue
		h := terrain_height(p.x, p.y)
		if h > TREE_MAX_HEIGHT || terrain_normal(p.x, p.y).y < TREE_MAX_SLOPE_Y do continue
		if !tree_has_room(len(verts), TREE_MAX_VERTS) do break
		append(&placed, p)
		planted += 1
		tree_emit_tree(verts, idx, {p.x, h, p.y}, p_biome, &rng)
	}

	if tree_rng_f32(&rng) < 0.125 {
		if p, ok := tree_find_spot(&rng, x0, z0, BOULDER_EDGE_MARGIN, TREE_PROP_SPACING, placed[:]);
		   ok && tree_has_room(len(verts), 3 * BLOB_VERTS) {
			append(&placed, p)
			tree_emit_boulders(verts, idx, {p.x, terrain_height(p.x, p.y), p.y}, &rng)
		}
	}

	for _ in 0 ..< 3 {
		p, ok := tree_find_spot(&rng, x0, z0, PROP_EDGE_MARGIN, TREE_PROP_SPACING, placed[:])
		if !ok || !tree_has_room(len(verts), BLOB_VERTS) do continue
		append(&placed, p)
		r := tree_rng_range(&rng, 0.7, 1.4)
		tree_emit_rock(verts, idx, {p.x, terrain_height(p.x, p.y) + 0.2 * r, p.y}, r, &rng)
	}

	for _ in 0 ..< 3 {
		p, ok := tree_find_spot(&rng, x0, z0, PROP_EDGE_MARGIN, TREE_PROP_SPACING, placed[:])
		if !ok || !tree_has_room(len(verts), BLOB_VERTS) do continue
		append(&placed, p)
		tree_emit_bush(verts, idx, {p.x, terrain_height(p.x, p.y), p.y}, tree_rng_range(&rng, 0.6, 1.0), &rng)
	}
}

tree_has_room :: proc(n, need: int) -> bool {
	return n + need <= TREE_VERT_CAP
}

// Random spot inside the chunk, away from edges, origin and other props.
// Gives up after 40 tries; the caller just skips that object.
tree_find_spot :: proc(rng: ^Tree_Rng, x0, z0, margin, spacing: f32, placed: [][2]f32) -> (p: [2]f32, ok: bool) {
	for _ in 0 ..< 40 {
		p = {
			x0 + tree_rng_range(rng, margin, CHUNK_SIZE - margin),
			z0 + tree_rng_range(rng, margin, CHUNK_SIZE - margin),
		}
		if linalg.length(p) < TREE_ORIGIN_KEEP_OUT do continue
		ok = true
		for q in placed {
			if linalg.distance(p, q) < spacing {
				ok = false
				break
			}
		}
		if ok do return
	}
	return
}

tree_pick_species :: proc(rng: ^Tree_Rng, biome: f32) -> Tree_Species {
	r := tree_rng_f32(rng)
	if biome < 0.35 {
		return r < 0.1 ? .Autumn : .Oak
	}
	forest := min(max((biome - 0.35) / 0.4, 0), 1)
	if r < 0.05 do return .Autumn
	if r < 0.05 + 0.9 * (1 - forest) do return .Oak
	return tree_rng_f32(rng) < 0.5 ? .Pine : .Broad
}

tree_emit_tree :: proc(verts: ^[dynamic]gbbfx.VertexData, idx: ^[dynamic]u32, base: [3]f32, biome: f32, rng: ^Tree_Rng) {
	switch tree_pick_species(rng, biome) {
	case .Oak:
		tree_emit_oak(verts, idx, base, false, rng)
	case .Autumn:
		tree_emit_oak(verts, idx, base, true, rng)
	case .Pine:
		tree_emit_pine(verts, idx, base, rng)
	case .Broad:
		tree_emit_broad(verts, idx, base, rng)
	}
}

// Thick trunk, two outward stubs, 5-7 blobs in a wide umbrella (~1.3:1 w:h).
tree_emit_oak :: proc(verts: ^[dynamic]gbbfx.VertexData, idx: ^[dynamic]u32, base: [3]f32, autumn: bool, rng: ^Tree_Rng) {
	s := tree_rng_range(rng, 0.8, 1.0)
	h := tree_rng_range(rng, 3.0, 4.5) * s
	bend := tree_rng_range(rng, -0.12, 0.12) * s
	top := tree_emit_trunk(verts, idx, base, 0.45 * s, h, bend, TREE_BARK_OAK)

	for i in 0 ..< 2 {
		t := 0.45 + 0.25 * f32(i)
		start := base + {bend * t * t, t * h, 0}
		a := tree_rng_range(rng, 0, 2 * math.PI) + f32(i) * math.PI
		dir := linalg.normalize([3]f32{math.cos(a), 0.6, math.sin(a)})
		path := [2][3]f32{start, start + dir * (1.25 * s)}
		radii := [2]f32{0.16 * s, 0.05 * s}
		tree_tube(verts, idx, path[:], radii[:], TREE_BARK_OAK)
	}

	n := 5 + int(tree_rng_f32(rng) * 3)
	blobs: [7]Tree_Blob
	for i in 0 ..< n {
		c := top
		if i > 0 {
			a := 2 * math.PI * f32(i) / f32(n) + tree_rng_range(rng, -0.3, 0.3)
			d := tree_rng_range(rng, 0.3, 0.6) * s
			c += {math.cos(a) * d, tree_rng_range(rng, -0.2, 0.2) * s, math.sin(a) * d}
		}
		r := tree_rng_range(rng, 1.3, 2.0) * s
		col := TREE_LEAF_OAK
		if autumn {
			palette := TREE_LEAF_AUTUMN
			col = palette[int(tree_rng_f32(rng) * 3)]
		}
		lift := (c.y - top.y) / s // lighter on top
		shade := tree_rng_range(rng, 0.9, 1.0) + 0.05 * lift
		blobs[i] = Tree_Blob{c = c, radii = {r, 0.8 * r, r}, color = col * shade, kind = 2}
	}
	tree_emit_crown(verts, idx, blobs[:n])
}

// Thin trunk, 5-6 drooping cone tiers shrinking upward. Tiers are kind 2 so tips sway.
tree_emit_pine :: proc(verts: ^[dynamic]gbbfx.VertexData, idx: ^[dynamic]u32, base: [3]f32, rng: ^Tree_Rng) {
	s := tree_rng_range(rng, 0.8, 1.0)
	h := tree_rng_range(rng, 6.0, 9.0) * s
	tree_emit_trunk(verts, idx, base, 0.2 * s, h, 0, TREE_BARK_PINE)

	n := 5 + int(tree_rng_f32(rng) * 2)
	step := 0.7 * h / f32(n)
	for i in 0 ..< n {
		frac := f32(i) / f32(n)
		radius := s * (2.6 - 1.8 * frac)
		shade := 0.9 + 0.2 * frac
		tree_emit_cone(verts, idx, base + {0, 0.25 * h + f32(i) * step, 0}, radius, 2.4 * step, 0.15 * radius, TREE_LEAF_PINE * shade, 0.4 + 0.5 * frac)
	}
}

// Very tall grey-brown trunk with a high crown of 4-5 blobs kept within 3 m of the trunk.
tree_emit_broad :: proc(verts: ^[dynamic]gbbfx.VertexData, idx: ^[dynamic]u32, base: [3]f32, rng: ^Tree_Rng) {
	s := tree_rng_range(rng, 0.8, 1.0)
	h := tree_rng_range(rng, 8.0, 11.0) * s
	bend := tree_rng_range(rng, -0.1, 0.1) * s
	top := tree_emit_trunk(verts, idx, base, 0.5 * s, h, bend, TREE_BARK_BROAD)

	n := 4 + int(tree_rng_f32(rng) * 2)
	blobs: [5]Tree_Blob
	for i in 0 ..< n {
		a := 2 * math.PI * f32(i) / f32(n) + tree_rng_range(rng, -0.3, 0.3)
		d := tree_rng_range(rng, 0.0, 0.15) * s
		c := top + {math.cos(a) * d, tree_rng_range(rng, -0.5, 0.3) * s, math.sin(a) * d}
		r := tree_rng_range(rng, 2.0, 2.8) * s
		shade := tree_rng_range(rng, 0.9, 1.0)
		blobs[i] = Tree_Blob{c = c, radii = {r, 0.8 * r, r}, color = TREE_LEAF_BROAD * shade, kind = 2}
	}
	tree_emit_crown(verts, idx, blobs[:n])
}

tree_emit_rock :: proc(verts: ^[dynamic]gbbfx.VertexData, idx: ^[dynamic]u32, c: [3]f32, r: f32, rng: ^Tree_Rng) {
	shade := tree_rng_range(rng, 0.85, 1.1)
	tree_emit_blob(verts, idx, Tree_Blob{c = c, radii = {r, 0.6 * r, r}, color = TREE_ROCK * shade, rough = 0.2, seed = u32(rng.state)})
}

// Three rocks stacked upward, each 1.5..3 m radius.
tree_emit_boulders :: proc(verts: ^[dynamic]gbbfx.VertexData, idx: ^[dynamic]u32, ground: [3]f32, rng: ^Tree_Rng) {
	prev := tree_rng_range(rng, 1.5, 3.0)
	c := ground + {0, 0.2 * prev, 0}
	tree_emit_rock(verts, idx, c, prev, rng)
	for _ in 1 ..< 3 {
		r := tree_rng_range(rng, 1.5, 3.0)
		c += {tree_rng_range(rng, -0.3, 0.3), 0.8 * 0.6 * (prev + r), tree_rng_range(rng, -0.3, 0.3)}
		tree_emit_rock(verts, idx, c, r, rng)
		prev = r
	}
}

tree_emit_bush :: proc(verts: ^[dynamic]gbbfx.VertexData, idx: ^[dynamic]u32, ground: [3]f32, r: f32, rng: ^Tree_Rng) {
	c := ground + {0, 0.4 * r, 0}
	shade := tree_rng_range(rng, 0.9, 1.1)
	tree_emit_blob(verts, idx, Tree_Blob{c = c, radii = {r, 0.7 * r, r}, color = TREE_BUSH_LEAF * shade, kind = 2, wlo = c.y - 0.7 * r, whi = c.y + 0.7 * r})
}

// Shared canopy: every blob pivots normals on the crown centre (centroid lowered 20% of crown height).
tree_emit_crown :: proc(verts: ^[dynamic]gbbfx.VertexData, idx: ^[dynamic]u32, blobs: []Tree_Blob) {
	lo, hi := f32(1e9), f32(-1e9)
	sum: [3]f32
	for b in blobs {
		lo = min(lo, b.c.y - b.radii.y)
		hi = max(hi, b.c.y + b.radii.y)
		sum += b.c
	}
	pivot := sum / f32(len(blobs)) - {0, 0.2 * (hi - lo), 0}
	for &b in blobs {
		b.crown = pivot
		b.crown_w = 0.7
		b.wlo = lo
		b.whi = hi
		tree_emit_blob(verts, idx, b)
	}
}

// Trunk along a slightly curved axis. Rings: buried flare, ground flare (1.6x, tapering within
// 0.6 m), waist, then taper to 75%. Returns top centre for the crown.
tree_emit_trunk :: proc(verts: ^[dynamic]gbbfx.VertexData, idx: ^[dynamic]u32, base: [3]f32, r, h, bend: f32, color: [3]f32) -> [3]f32 {
	ys := [3]f32{-0.5, 0, 0.6}
	path: [7][3]f32
	rad: [7]f32
	for i in 0 ..< 7 {
		y := 0.6 + (h - 0.6) * f32(i - 2) / 4
		if i < 3 do y = ys[i]
		yc := max(y, 0) / h
		path[i] = base + {bend * yc * yc, y, 0}
		if i < 2 {
			rad[i] = 1.6 * r
		} else if i == 2 {
			rad[i] = r
		} else {
			rad[i] = r * (1 - 0.25 * f32(i - 2) / 4)
		}
	}
	tree_tube(verts, idx, path[:], rad[:], color)
	return base + {bend, h, 0}
}

// Tube along a polyline with per-ring radius; shade darkens toward the first ring.
tree_tube :: proc(verts: ^[dynamic]gbbfx.VertexData, idx: ^[dynamic]u32, path: [][3]f32, rad: []f32, color: [3]f32) {
	first := u32(len(verts))
	n := len(path)
	for i in 0 ..< n {
		axis := linalg.normalize(path[min(i + 1, n - 1)] - path[max(i - 1, 0)])
		ref := [3]f32{1, 0, 0}
		if abs(axis.x) > 0.9 do ref = {0, 0, 1}
		u := linalg.normalize(linalg.cross(axis, ref))
		w := linalg.cross(axis, u)
		col := color * (0.8 + 0.2 * f32(i) / f32(n - 1))
		for k in 0 ..< TREE_SIDES {
			a := 2 * math.PI * f32(k) / TREE_SIDES
			dir := u * math.cos(a) + w * math.sin(a)
			append(
				verts,
				gbbfx.VertexData {
					position = path[i] + dir * rad[i],
					color = {col.r, col.g, col.b, 1},
					uv = {0, 0},
					normal = dir,
				},
			)
		}
	}
	tree_grid(verts^, idx, first, n, TREE_SIDES)
}

// Cone tier: ring at `base` lowered by droop, apex above. uv.x = base_w at ring, 1 at tip; kind 2.
tree_emit_cone :: proc(verts: ^[dynamic]gbbfx.VertexData, idx: ^[dynamic]u32, base: [3]f32, radius, height, droop: f32, color: [3]f32, base_w: f32) {
	first := u32(len(verts))
	col := [4]f32{color.r, color.g, color.b, 1}
	for k in 0 ..< TREE_SIDES {
		a := 2 * math.PI * f32(k) / TREE_SIDES
		dir := [3]f32{math.cos(a), 0, math.sin(a)}
		append(
			verts,
			gbbfx.VertexData {
				position = base + dir * radius - {0, droop, 0},
				color = col,
				uv = {base_w, 2},
				normal = linalg.normalize(dir * 0.8 + {0, 0.4, 0}),
			},
		)
	}
	append(verts, gbbfx.VertexData{position = base + {0, height, 0}, color = col, uv = {1, 2}, normal = {0, 1, 0}})
	apex := first + TREE_SIDES
	for k in 0 ..< TREE_SIDES {
		tree_add_tri(verts^, idx, first + u32(k), first + u32((k + 1) % TREE_SIDES), apex)
	}
}

// Squashed UV sphere (BLOB_SEGS x BLOB_RINGS bands), optional radial jitter and crown-pivot normals.
tree_emit_blob :: proc(verts: ^[dynamic]gbbfx.VertexData, idx: ^[dynamic]u32, b: Tree_Blob) {
	first := u32(len(verts))
	for r in 0 ..= BLOB_RINGS {
		phi := math.PI * f32(r) / BLOB_RINGS
		for s in 0 ..< BLOB_SEGS {
			th := 2 * math.PI * f32(s) / BLOB_SEGS
			d := [3]f32{math.sin(phi) * math.cos(th), math.cos(phi), math.sin(phi) * math.sin(th)}
			jit := 1 + b.rough * (2 * tree_hash(b.seed, u32(r), u32(s)) - 1)
			p := b.c + d * b.radii * jit
			n := linalg.normalize(d / b.radii)
			if b.crown_w > 0 {
				cn := linalg.normalize(p - b.crown)
				n = linalg.normalize(n + (cn - n) * b.crown_w)
			}
			t: f32
			if b.whi > b.wlo do t = min(max((p.y - b.wlo) / (b.whi - b.wlo), 0), 1)
			append(
				verts,
				gbbfx.VertexData {
					position = p,
					color = {b.color.r, b.color.g, b.color.b, 1},
					uv = {t, b.kind},
					normal = n,
				},
			)
		}
	}
	tree_grid(verts^, idx, first, BLOB_RINGS + 1, BLOB_SEGS)
}

// Triangulates a rows x cols grid of vertices (cols wraps around). Winding is chosen per
// triangle so it faces the averaged vertex normal.
tree_grid :: proc(verts: [dynamic]gbbfx.VertexData, idx: ^[dynamic]u32, first: u32, rows, cols: int) {
	for r in 0 ..< rows - 1 {
		for c in 0 ..< cols {
			c1 := (c + 1) % cols
			a := first + u32(r * cols + c)
			b := first + u32(r * cols + c1)
			d := first + u32((r + 1) * cols + c)
			e := first + u32((r + 1) * cols + c1)
			tree_add_tri(verts, idx, a, b, e)
			tree_add_tri(verts, idx, a, e, d)
		}
	}
}

tree_add_tri :: proc(verts: [dynamic]gbbfx.VertexData, idx: ^[dynamic]u32, a, b, c: u32) {
	pa, pb, pc := verts[a].position, verts[b].position, verts[c].position
	n := verts[a].normal + verts[b].normal + verts[c].normal
	j, k := b, c
	if linalg.dot(linalg.cross(pb - pa, pc - pa), n) < 0 do j, k = k, j
	append(idx, a, j, k)
}
