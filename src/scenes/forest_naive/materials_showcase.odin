// Three cubes in front of the spawn view: toon, glass, emissive (bloom picks up the glow).
// Everything is scope-owned (material_create, draw_create with Mesh_Data), so no destroy.
package forest_naive

import gfx "../../engine/gfx"

SHOWCASE_COUNT :: 3
SHOWCASE_HALF :: 1.0 // showcase_cube is 2x2x2 about its origin, drawn unscaled
SHOWCASE_DROP :: 1.2 // spawn height above the terrain under each cube

// Centres at x -3/0/+3, z -10; each rests SHOWCASE_DROP above the terrain under it.
showcase_spawn :: proc() -> (pos: [SHOWCASE_COUNT][3]f32) {
	xs := [SHOWCASE_COUNT]f32{-3, 0, 3}
	for x, i in xs do pos[i] = {x, terrain_height(x, -10) + SHOWCASE_DROP, -10}
	return
}

showcase_create :: proc(gfx_ctx: ^gfx.Device, spawn: [SHOWCASE_COUNT][3]f32) -> (draws: [SHOWCASE_COUNT]int) {
	white := gfx.texture_create_rgba8(gfx_ctx, 1, 1, false, false)
	pixels := gfx.texture_get(gfx_ctx, white)
	pixels._temporary_raw_data = []u8{255, 255, 255, 255}
	gfx.uploader_begin(&gfx_ctx.renderer.uploader)
	gfx.uploader_upload_texture(&gfx_ctx.renderer.uploader, white)
	gfx.uploader_flush_blocking(&gfx_ctx.renderer.uploader)
	pixels._temporary_raw_data = nil

	verts, idx := showcase_cube()
	// Toon needs vertex color for the tint (texture is white).
	for &v in verts do v.color = {0.9, 0.35, 0.25, 1}
	toon := gfx.material_create(gfx_ctx, {kind = .Toon, texture = white})
	draws[0] = gfx.draw_create(gfx_ctx, {mesh = gfx.Mesh_Data{verts[:], idx[:]}, material = toon, position = spawn[0]})

	for &v in verts do v.color = {1, 1, 1, 1}
	glass := gfx.material_create(gfx_ctx, {kind = .Glass, tint = {0.6, 0.85, 1, 0.3}})
	draws[1] = gfx.draw_create(gfx_ctx, {mesh = gfx.Mesh_Data{verts[:], idx[:]}, material = glass, position = spawn[1], layer = .TRANSPARENT})

	emissive := gfx.material_create(gfx_ctx, {kind = .Emissive, tint = {1, 0.6, 0.15, 1}, emission = 4})
	draws[2] = gfx.draw_create(gfx_ctx, {mesh = gfx.Mesh_Data{verts[:], idx[:]}, material = emissive, position = spawn[2]})
	return
}

// 2x2x2 cube centred at origin, outward normals.
showcase_cube :: proc() -> (verts: [24]gfx.VertexData, idx: [36]u32) {
	faces := [6][3][3]f32 {
		// normal, u axis, v axis
		{{0, 0, 1}, {1, 0, 0}, {0, 1, 0}},
		{{0, 0, -1}, {-1, 0, 0}, {0, 1, 0}},
		{{1, 0, 0}, {0, 0, -1}, {0, 1, 0}},
		{{-1, 0, 0}, {0, 0, 1}, {0, 1, 0}},
		{{0, 1, 0}, {1, 0, 0}, {0, 0, -1}},
		{{0, -1, 0}, {1, 0, 0}, {0, 0, 1}},
	}
	corners := [4][2]f32{{-1, -1}, {1, -1}, {1, 1}, {-1, 1}}
	for f, i in faces {
		for c, j in corners {
			verts[i * 4 + j] = {
				position = f[0] + f[1] * c.x + f[2] * c.y,
				color    = {1, 1, 1, 1},
				uv       = {c.x * 0.5 + 0.5, c.y * 0.5 + 0.5},
				normal   = f[0],
			}
		}
		b := u32(i * 4)
		copy(idx[i * 6:], []u32{b, b + 1, b + 2, b, b + 2, b + 3})
	}
	return
}
