package forest_naive

import "core:testing"
import gfx "../../engine/gfx"

// Collider recording must not change the drawn trees, and every collider sits inside its chunk.
@(test)
trees_colliders_match_mesh :: proc(t: ^testing.T) {
	total := 0
	for cz in COLLIDER_CHUNK0 ..< COLLIDER_CHUNK0 + COLLIDER_CHUNKS {
		for cx in COLLIDER_CHUNK0 ..< COLLIDER_CHUNK0 + COLLIDER_CHUNKS {
			verts_a: [dynamic]gfx.VertexData
			idx_a: [dynamic]u32
			verts_b: [dynamic]gfx.VertexData
			idx_b: [dynamic]u32
			cols: [dynamic]Tree_Collider
			defer delete(verts_a)
			defer delete(idx_a)
			defer delete(verts_b)
			defer delete(idx_b)
			defer delete(cols)

			terrain_chunk(cx, cz, &verts_a, &idx_a)
			trees_chunk(cx, cz, &verts_a, &idx_a, nil)
			terrain_chunk(cx, cz, &verts_b, &idx_b)
			trees_chunk(cx, cz, &verts_b, &idx_b, &cols)

			testing.expect_value(t, len(verts_b), len(verts_a))
			testing.expect_value(t, len(idx_b), len(idx_a))
			if len(verts_a) == len(verts_b) {
				for i in 0 ..< len(verts_a) do testing.expect(t, verts_a[i] == verts_b[i], "vertex differs with collider recording on")
			}

			x0, z0 := chunk_origin(cx, cz)
			for c in cols {
				total += 1
				testing.expect(t, c.p0.x >= x0 && c.p0.x < x0 + CHUNK_SIZE && c.p0.z >= z0 && c.p0.z < z0 + CHUNK_SIZE, "collider outside its chunk")
			}
		}
	}
	testing.expect(t, total > 0, "no tree colliders in collider region")
}
