package forest_instanced

import "core:math"
import "core:math/linalg"
import gfx "../../engine/gfx"
import naive "../forest_naive"

// Local-space variant meshes (origin at base centre on the ground, y up, scale 1) drawn as
// GPU instances. u16 indices: every variant stays far below 65535 verts.
Variant_Data :: struct {
	verts: [dynamic]gfx.VertexData,
	idx:   [dynamic]u16,
}

BLOB_SEGS :: 8
BLOB_RINGS :: 5
TREE_SIDES :: 8

TREE_BARK_OAK :: [3]f32{0.40, 0.27, 0.16}
TREE_BARK_PINE :: [3]f32{0.38, 0.26, 0.16}
TREE_BARK_BROAD :: [3]f32{0.45, 0.36, 0.28}
TREE_LEAF_OAK :: [3]f32{0.50, 0.72, 0.20}
TREE_LEAF_PINE :: [3]f32{0.16, 0.42, 0.28}
TREE_LEAF_BROAD :: [3]f32{0.22, 0.55, 0.20}
TREE_LEAF_AUTUMN :: [3][3]f32{{0.95, 0.55, 0.15}, {0.85, 0.35, 0.12}, {0.95, 0.80, 0.20}}
TREE_BUSH_LEAF :: [3]f32{0.30, 0.60, 0.18}
TREE_ROCK :: [3]f32{0.55, 0.54, 0.52}

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

// Splitmix64 stream. Variants seed from their index.
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

// Builds every variant mesh once. Each variant has a fixed seed, so output is deterministic.
variants_build :: proc() -> [naive.VARIANT_COUNT]Variant_Data {
	out: [naive.VARIANT_COUNT]Variant_Data
	for v in 0 ..< naive.VARIANT_COUNT {
		rng := Tree_Rng{state = 0x0F0E5713 + u64(v) * 0x9E3779B97F4A7C15}
		m := &out[v]
		switch {
		case v < naive.VARIANT_PINE_FIRST:
			variant_emit_oak(m, false, &rng)
		case v < naive.VARIANT_BROAD_FIRST:
			variant_emit_pine(m, &rng)
		case v < naive.VARIANT_AUTUMN:
			variant_emit_broad(m, &rng)
		case v == naive.VARIANT_AUTUMN:
			variant_emit_oak(m, true, &rng)
		case v < naive.VARIANT_BUSH_FIRST:
			variant_emit_rock(m, v - naive.VARIANT_ROCK_FIRST, &rng)
		case:
			variant_emit_bush(m, &rng)
		}
		assert(len(m.verts) < 65535, "forest_instanced: variant exceeds u16 index range")
	}
	return out
}

// Thick trunk, two outward stubs, 5-7 blobs in a wide umbrella (~1.3:1 w:h). Local space, ~5 m.
variant_emit_oak :: proc(m: ^Variant_Data, autumn: bool, rng: ^Tree_Rng) {
	s := tree_rng_range(rng, 0.9, 1.0)
	h := tree_rng_range(rng, 3.0, 3.5) * s
	bend := tree_rng_range(rng, -0.12, 0.12) * s
	top := tree_emit_trunk(m, 0.45 * s, h, bend, TREE_BARK_OAK)

	for i in 0 ..< 2 {
		t := 0.45 + 0.25 * f32(i)
		start := [3]f32{bend * t * t, t * h, 0}
		a := tree_rng_range(rng, 0, 2 * math.PI) + f32(i) * math.PI
		dir := linalg.normalize([3]f32{math.cos(a), 0.6, math.sin(a)})
		path := [2][3]f32{start, start + dir * (1.25 * s)}
		radii := [2]f32{0.16 * s, 0.05 * s}
		tree_tube(m, path[:], radii[:], TREE_BARK_OAK)
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
	tree_emit_crown(m, blobs[:n])
}

// Thin trunk, 5-6 drooping cone tiers shrinking upward. Local space, ~8 m.
variant_emit_pine :: proc(m: ^Variant_Data, rng: ^Tree_Rng) {
	s := tree_rng_range(rng, 0.9, 1.0)
	h := tree_rng_range(rng, 6.5, 7.5) * s
	tree_emit_trunk(m, 0.2 * s, h, 0, TREE_BARK_PINE)

	n := 5 + int(tree_rng_f32(rng) * 2)
	step := 0.7 * h / f32(n)
	for i in 0 ..< n {
		frac := f32(i) / f32(n)
		radius := s * (2.6 - 1.8 * frac)
		shade := 0.9 + 0.2 * frac
		tree_emit_cone(m, {0, 0.25 * h + f32(i) * step, 0}, radius, 2.4 * step, 0.15 * radius, TREE_LEAF_PINE * shade, 0.4 + 0.5 * frac)
	}
}

// Very tall grey-brown trunk with a high crown of 4-5 blobs kept within 3 m of the trunk. Local, ~10 m.
variant_emit_broad :: proc(m: ^Variant_Data, rng: ^Tree_Rng) {
	s := tree_rng_range(rng, 0.9, 1.0)
	h := tree_rng_range(rng, 7.5, 8.5) * s
	bend := tree_rng_range(rng, -0.1, 0.1) * s
	top := tree_emit_trunk(m, 0.5 * s, h, bend, TREE_BARK_BROAD)

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
	tree_emit_crown(m, blobs[:n])
}

// Rock variant k: 1 + k blobs (k = 0..2), centred on the origin so it sits half buried.
variant_emit_rock :: proc(m: ^Variant_Data, k: int, rng: ^Tree_Rng) {
	r := tree_rng_range(rng, 0.7, 0.9)
	shade := tree_rng_range(rng, 0.85, 1.1)
	for j in 0 ..= k {
		c: [3]f32
		rj := r
		if j > 0 {
			a := f32(j) * 2.1
			rj = r * (1 - 0.25 * f32(j))
			c = {math.cos(a) * 0.7 * r, -0.1 * r * f32(j), math.sin(a) * 0.7 * r}
		}
		seed := u32(tree_rng_f32(rng) * 4294967040.0)
		tree_emit_blob(m, Tree_Blob{c = c, radii = {rj, 0.6 * rj, rj}, color = TREE_ROCK * shade, rough = 0.2, seed = seed})
	}
}

// Single squashed leaf ball on the ground, sways via kind 2; wind weight ramps over its height.
variant_emit_bush :: proc(m: ^Variant_Data, rng: ^Tree_Rng) {
	r := tree_rng_range(rng, 0.6, 0.8)
	c := [3]f32{0, 0.4 * r, 0}
	shade := tree_rng_range(rng, 0.9, 1.1)
	tree_emit_blob(m, Tree_Blob{c = c, radii = {r, 0.7 * r, r}, color = TREE_BUSH_LEAF * shade, kind = 2, wlo = c.y - 0.7 * r, whi = c.y + 0.7 * r})
}

// Trunk along a slightly curved axis from the origin. Rings: buried flare (-0.2 m), ground flare
// (1.6x), waist, then taper to 75%. Returns top centre for the crown.
tree_emit_trunk :: proc(m: ^Variant_Data, r, h, bend: f32, color: [3]f32) -> [3]f32 {
	ys := [3]f32{-0.2, 0, 0.6}
	path: [7][3]f32
	rad: [7]f32
	for i in 0 ..< 7 {
		y := 0.6 + (h - 0.6) * f32(i - 2) / 4
		if i < 3 do y = ys[i]
		yc := max(y, 0) / h
		path[i] = {bend * yc * yc, y, 0}
		if i < 2 {
			rad[i] = 1.6 * r
		} else if i == 2 {
			rad[i] = r
		} else {
			rad[i] = r * (1 - 0.25 * f32(i - 2) / 4)
		}
	}
	tree_tube(m, path[:], rad[:], color)
	return {bend, h, 0}
}

// Tube along a polyline with per-ring radius; shade darkens toward the first ring.
tree_tube :: proc(m: ^Variant_Data, path: [][3]f32, rad: []f32, color: [3]f32) {
	first := u16(len(m.verts))
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
				&m.verts,
				gfx.VertexData {
					position = path[i] + dir * rad[i],
					color = {col.r, col.g, col.b, 1},
					uv = {0, 0},
					normal = dir,
				},
			)
		}
	}
	tree_grid(m, first, n, TREE_SIDES)
}

// Cone tier: ring at `base` lowered by droop, apex above. uv.x = base_w at ring, 1 at tip; kind 2.
tree_emit_cone :: proc(m: ^Variant_Data, base: [3]f32, radius, height, droop: f32, color: [3]f32, base_w: f32) {
	first := u16(len(m.verts))
	col := [4]f32{color.r, color.g, color.b, 1}
	for k in 0 ..< TREE_SIDES {
		a := 2 * math.PI * f32(k) / TREE_SIDES
		dir := [3]f32{math.cos(a), 0, math.sin(a)}
		append(
			&m.verts,
			gfx.VertexData {
				position = base + dir * radius - {0, droop, 0},
				color = col,
				uv = {base_w, 2},
				normal = linalg.normalize(dir * 0.8 + {0, 0.4, 0}),
			},
		)
	}
	append(&m.verts, gfx.VertexData{position = base + {0, height, 0}, color = col, uv = {1, 2}, normal = {0, 1, 0}})
	apex := u16(int(first) + TREE_SIDES)
	for k in 0 ..< TREE_SIDES {
		tree_add_tri(m, first + u16(k), first + u16((k + 1) % TREE_SIDES), apex)
	}
}

// Shared canopy: every blob pivots normals on the crown centre (centroid lowered 20% of crown height).
tree_emit_crown :: proc(m: ^Variant_Data, blobs: []Tree_Blob) {
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
		tree_emit_blob(m, b)
	}
}

// Squashed UV sphere (BLOB_SEGS x BLOB_RINGS bands), optional radial jitter and crown-pivot normals.
tree_emit_blob :: proc(m: ^Variant_Data, b: Tree_Blob) {
	first := u16(len(m.verts))
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
				&m.verts,
				gfx.VertexData {
					position = p,
					color = {b.color.r, b.color.g, b.color.b, 1},
					uv = {t, b.kind},
					normal = n,
				},
			)
		}
	}
	tree_grid(m, first, BLOB_RINGS + 1, BLOB_SEGS)
}

// Triangulates a rows x cols grid of vertices (cols wraps around).
tree_grid :: proc(m: ^Variant_Data, first: u16, rows, cols: int) {
	for r in 0 ..< rows - 1 {
		for c in 0 ..< cols {
			c1 := (c + 1) % cols
			a := u16(int(first) + r * cols + c)
			b := u16(int(first) + r * cols + c1)
			d := u16(int(first) + (r + 1) * cols + c)
			e := u16(int(first) + (r + 1) * cols + c1)
			tree_add_tri(m, a, b, e)
			tree_add_tri(m, a, e, d)
		}
	}
}

// Winding is chosen per triangle so it faces the averaged vertex normal.
tree_add_tri :: proc(m: ^Variant_Data, a, b, c: u16) {
	pa, pb, pc := m.verts[a].position, m.verts[b].position, m.verts[c].position
	n := m.verts[a].normal + m.verts[b].normal + m.verts[c].normal
	j, k := b, c
	if linalg.dot(linalg.cross(pb - pa, pc - pa), n) < 0 do j, k = k, j
	append(&m.idx, a, j, k)
}
