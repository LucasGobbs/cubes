// Stencil proof: a mask cube writes stencil=1 (compare ALWAYS, pass REPLACE), then a larger cube with compare EQUAL ref=1 shows only inside the mask.
// Mask is on WORLD and masked cube on TRANSPARENT: the layer sort key puts WORLD first, so the mask always draws first.
package stencil

import engine "../../engine"
import gfx "../../engine/gfx"

Stencil_State :: struct {
	mask:   gfx.Material,
	masked: gfx.Material,
}

stencil_scene :: proc() -> engine.Scene {
	return {name = "Stencil", create = stencil_create, tick = stencil_tick, destroy = stencil_destroy}
}

stencil_create :: proc(demo: ^engine.Scene, ctx: ^engine.Context) -> bool {
	gfx_ctx := &ctx.gfx
	state := new(Stencil_State)
	demo.state = state

	write_face := gfx.Stencil_Face_Desc{compare_op = .ALWAYS, pass_op = .REPLACE, fail_op = .KEEP, depth_fail_op = .KEEP}
	test_face := gfx.Stencil_Face_Desc{compare_op = .EQUAL, pass_op = .KEEP, fail_op = .KEEP, depth_fail_op = .KEEP}
	write := gfx.create_unlit_stencil_pipeline(gfx_ctx, {enabled = true, front = write_face, back = write_face, compare_mask = 0xFF, write_mask = 0xFF, reference = 1})
	test := gfx.create_unlit_stencil_pipeline(gfx_ctx, {enabled = true, front = test_face, back = test_face, compare_mask = 0xFF, write_mask = 0, reference = 1})
	state.mask = gfx.material_make(write)
	gfx.set_unlit_color(&state.mask, {0.2, 0.4, 1, 1})
	state.masked = gfx.material_make(test)
	gfx.set_unlit_color(&state.masked, {1, 0.5, 0.1, 1})

	verts, idx := stencil_cube()
	gfx.draw_create(gfx_ctx, {mesh = gfx.Mesh_Data{verts[:], idx[:]}, material = &state.mask, position = {0, 0, -3}, scale = {1.5, 1.5, 1.5}})
	gfx.draw_create(gfx_ctx, {mesh = gfx.Mesh_Data{verts[:], idx[:]}, material = &state.masked, position = {0, 0, 0}, scale = {4, 4, 4}, layer = .TRANSPARENT})
	return true
}

// Device-list draws are submitted by gfx.render from tick, as in forest_naive.
stencil_tick :: proc(demo: ^engine.Scene, ctx: ^engine.Context, delta_time: f32) {
	gfx.render(&ctx.gfx)
}

stencil_destroy :: proc(demo: ^engine.Scene, ctx: ^engine.Context) {
	state := cast(^Stencil_State)demo.state
	gfx.material_destroy(&state.mask)
	gfx.material_destroy(&state.masked)
	free(state)
}

// Unit cube (side 1) centered at origin, outward winding; same face layout as forest_naive's showcase cube.
stencil_cube :: proc() -> (verts: [24]gfx.VertexData, idx: [36]u32) {
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
				position = (f[0] + f[1] * c.x + f[2] * c.y) * 0.5,
				color = {1, 1, 1, 1},
				uv = {c.x * 0.5 + 0.5, c.y * 0.5 + 0.5},
				normal = f[0],
			}
		}
		b := u32(i * 4)
		copy(idx[i * 6:], []u32{b, b + 1, b + 2, b, b + 2, b + 3})
	}
	return
}
