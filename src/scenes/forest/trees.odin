package forest

import "core:math"
import "core:math/linalg"
import gbbfx "../../gbbfx"

// Typical chunk: ~10 trees (~150 verts each: 18 trunk + 2-3 canopy blobs of 48),
// ~3 rocks (30 verts), ~4 bushes (30 verts) => ~1.6k verts. Far below u16 range.

TREE_COUNT :: 10
TREE_ROCK_COUNT :: 3
TREE_BUSH_COUNT :: 4
TREE_MIN_SPACING :: 3.0
TREE_EDGE_MARGIN :: 2.0
TREE_ORIGIN_KEEP_OUT :: 6.0
TREE_MAX_SLOPE_Y :: 0.8

TREE_BARK :: [3]f32{0.40, 0.27, 0.16}
TREE_LEAF :: [3]f32{0.25, 0.52, 0.16}
TREE_BUSH_LEAF :: [3]f32{0.18, 0.38, 0.12}
TREE_ROCK :: [3]f32{0.50, 0.48, 0.44}

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

trees_chunk :: proc(cx, cz: int, verts: ^[dynamic]gbbfx.VertexData, idx: ^[dynamic]u32) {
	x0, z0 := chunk_origin(cx, cz)
	rng := Tree_Rng{state = u64(cx * CHUNKS_PER_SIDE + cz) * 0x9E3779B97F4A7C15 + 1}

	placed := make([dynamic][2]f32, 0, TREE_COUNT + TREE_ROCK_COUNT + TREE_BUSH_COUNT)
	defer delete(placed)

	for _ in 0 ..< TREE_COUNT {
		p, ok := tree_find_spot(&rng, x0, z0, placed[:])
		if !ok do continue
		if terrain_normal(p.x, p.y).y < TREE_MAX_SLOPE_Y do continue
		append(&placed, p)
		base := [3]f32{p.x, terrain_height(p.x, p.y), p.y}
		tree_emit_tree(verts, idx, base, &rng)
	}

	for _ in 0 ..< TREE_ROCK_COUNT {
		p, ok := tree_find_spot(&rng, x0, z0, placed[:])
		if !ok do continue
		append(&placed, p)
		r := tree_rng_range(&rng, 0.4, 1.1)
		center := [3]f32{p.x, terrain_height(p.x, p.y), p.y}
		tree_emit_blob(verts, idx, center, {r, 0.6 * r, r}, 6, 4, TREE_ROCK, 0, false)
	}

	for _ in 0 ..< TREE_BUSH_COUNT {
		p, ok := tree_find_spot(&rng, x0, z0, placed[:])
		if !ok do continue
		append(&placed, p)
		r := tree_rng_range(&rng, 0.5, 0.9)
		// Partly buried: center lifted by ~40% of radius above ground.
		center := [3]f32{p.x, terrain_height(p.x, p.y) + 0.4 * r, p.y}
		tree_emit_blob(verts, idx, center, {r, 0.7 * r, r}, 6, 4, TREE_BUSH_LEAF, 2, true)
	}
}

// Random spot inside the chunk, away from edges, origin and other props.
// Gives up after 40 tries; the caller just skips that object.
tree_find_spot :: proc(rng: ^Tree_Rng, x0, z0: f32, placed: [][2]f32) -> (p: [2]f32, ok: bool) {
	for _ in 0 ..< 40 {
		p = {
			x0 + tree_rng_range(rng, TREE_EDGE_MARGIN, CHUNK_SIZE - TREE_EDGE_MARGIN),
			z0 + tree_rng_range(rng, TREE_EDGE_MARGIN, CHUNK_SIZE - TREE_EDGE_MARGIN),
		}
		if linalg.length(p) < TREE_ORIGIN_KEEP_OUT do continue
		ok = true
		for q in placed {
			if linalg.distance(p, q) < TREE_MIN_SPACING {
				ok = false
				break
			}
		}
		if ok do return
	}
	return
}

tree_emit_tree :: proc(verts: ^[dynamic]gbbfx.VertexData, idx: ^[dynamic]u32, base: [3]f32, rng: ^Tree_Rng) {
	s := tree_rng_range(rng, 0.8, 1.4)
	h := tree_rng_range(rng, 3.5, 5.0) * s
	tree_emit_trunk(verts, idx, base, s, h)

	top := base + {0, h, 0}
	blobs := 2 + (tree_rng_f32(rng) < 0.5 ? 1 : 0)
	for i in 0 ..< blobs {
		c := top
		if i > 0 {
			a := tree_rng_range(rng, 0, 2 * math.PI)
			d := tree_rng_range(rng, 0.3, 0.5) * s
			c += {math.cos(a) * d, tree_rng_range(rng, -0.2, 0.6) * s, math.sin(a) * d}
		}
		r := tree_rng_range(rng, 1.6, 2.2) * s
		shade := tree_rng_range(rng, 0.9, 1.1)
		color := TREE_LEAF * shade
		tree_emit_blob(verts, idx, c, {r, 0.7 * r, r}, 8, 5, color, 2, true)
	}
}

// Tapered 6-sided trunk: rings at base, 60% height and top. Bottom is buried, top is covered by canopy.
tree_emit_trunk :: proc(verts: ^[dynamic]gbbfx.VertexData, idx: ^[dynamic]u32, base: [3]f32, s, h: f32) {
	SEGS :: 6
	ring_y := [3]f32{0, 0.6 * h, h}
	ring_r := [3]f32{0.35 * s, 0.18 * s, 0.12 * s}
	first := u32(len(verts))
	for i in 0 ..< 3 {
		for k in 0 ..< SEGS {
			a := 2 * math.PI * f32(k) / SEGS
			dir := [3]f32{math.cos(a), 0, math.sin(a)}
			append(
				verts,
				gbbfx.VertexData {
					position = base + {0, ring_y[i], 0} + dir * ring_r[i],
					color = {TREE_BARK.r, TREE_BARK.g, TREE_BARK.b, 1},
					uv = {0, 0},
					normal = dir,
				},
			)
		}
	}
	tree_grid(verts^, idx, first, 3, SEGS)
}

// Squashed UV sphere (segs x rings bands). sway: uv.x = height fraction (tips move), else 0 (rooted).
tree_emit_blob :: proc(
	verts: ^[dynamic]gbbfx.VertexData,
	idx: ^[dynamic]u32,
	c, radii: [3]f32,
	segs, rings: int,
	color: [3]f32,
	kind: f32,
	sway: bool,
) {
	first := u32(len(verts))
	for r in 0 ..= rings {
		phi := math.PI * f32(r) / f32(rings)
		for s in 0 ..< segs {
			th := 2 * math.PI * f32(s) / f32(segs)
			d := [3]f32{math.sin(phi) * math.cos(th), math.cos(phi), math.sin(phi) * math.sin(th)}
			p := c + d * radii
			t := sway ? (p.y - (c.y - radii.y)) / (2 * radii.y) : 0
			append(
				verts,
				gbbfx.VertexData {
					position = p,
					color = {color.r, color.g, color.b, 1},
					uv = {t, kind},
					normal = linalg.normalize(d / radii),
				},
			)
		}
	}
	tree_grid(verts^, idx, first, rings + 1, segs)
}

// Triangulates a rows x cols grid of vertices (cols wraps around). Winding is chosen per
// triangle so it faces the averaged vertex normal, same rule as proto_add_face.
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
