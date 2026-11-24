// Test gallery: a row of cubes and a poster quad, all textured with the window atlas.
package city

import engine "../../engine"
import gfx "../../engine/gfx"
import shader_parameters "../../shader_parameters"
import "core:math/linalg"

GALLERY_CUBE_COUNT :: 5
GALLERY_CUBE_SIZE :: 32
GALLERY_CUBE_SPACING :: 48
GALLERY_CUBE_FIRST_X :: -96 // centre of the first cube
GALLERY_POSTER_SIZE :: 64
GALLERY_POSTER_Z :: -60

gallery_pipeline_create :: proc(gfx_ctx: ^gfx.Device) -> gfx.Pipeline_Handle {
	attributes := shader_parameters.city_vertex_attributes(gfx.VertexData)
	return gfx.pipeline_create(
		gfx_ctx,
		{
			vertex = shader_parameters.city_vertex(),
			fragment = shader_parameters.city_fragment(),
			vertex_attributes = attributes[:],
			vertex_stride = u32(size_of(gfx.VertexData)),
			depth_test = true,
			depth_write = true,
			cull_mode = .BACK,
			bind_draw = gallery_bind_draw,
		},
	)
}

gallery_bind_draw :: proc(user_data: rawptr, draw_context: ^gfx.Draw_Context, parameters: gfx.Draw_Parameters) {
	uniforms := shader_parameters.CityVertexUniforms {
		mvp = parameters.view_projection * parameters.model_transform,
	}
	gfx.draw_push_uniform(draw_context, shader_parameters.CITY_VERTEX_UNIFORM_BLOCK, &uniforms)
}

// Adds a quad at origin spanning u and v; u x v is the outward normal, so
// the triangles wind CCW from outside and BACK culling keeps the visible side.
gallery_add_quad :: proc(verts: ^[dynamic]gfx.VertexData, indices: ^[dynamic]u32, origin, u, v: gfx.Vec3) {
	normal := linalg.normalize(linalg.cross(u, v))
	corners := [4]gfx.Vec3{origin, origin + u, origin + u + v, origin + v}
	uvs := [4][2]f32{{0, 0}, {1, 0}, {1, 1}, {0, 1}}
	base := u32(len(verts))
	for i in 0 ..< 4 {
		append(verts, gfx.VertexData{position = corners[i], color = {1, 1, 1, 1}, uv = uvs[i], normal = normal})
	}
	append(indices, base, base + 1, base + 2, base, base + 2, base + 3)
}

// Cubes stand on y = 0, centred on z = 0. Built per call; the engine copies it at spawn.
gallery_mesh :: proc() -> gfx.Mesh_Data {
	verts := make([dynamic]gfx.VertexData, context.temp_allocator)
	indices := make([dynamic]u32, context.temp_allocator)

	s := f32(GALLERY_CUBE_SIZE)
	h := s / 2
	for i in 0 ..< GALLERY_CUBE_COUNT {
		cx := f32(GALLERY_CUBE_FIRST_X + i * GALLERY_CUBE_SPACING)
		gallery_add_quad(&verts, &indices, {cx + h, 0, -h}, {0, s, 0}, {0, 0, s}) // +X
		gallery_add_quad(&verts, &indices, {cx - h, 0, -h}, {0, 0, s}, {0, s, 0}) // -X
		gallery_add_quad(&verts, &indices, {cx - h, s, -h}, {0, 0, s}, {s, 0, 0}) // +Y
		gallery_add_quad(&verts, &indices, {cx - h, 0, -h}, {s, 0, 0}, {0, 0, s}) // -Y
		gallery_add_quad(&verts, &indices, {cx - h, 0, h}, {s, 0, 0}, {0, s, 0}) // +Z
		gallery_add_quad(&verts, &indices, {cx - h, 0, -h}, {0, s, 0}, {s, 0, 0}) // -Z
	}

	p := f32(GALLERY_POSTER_SIZE)
	gallery_add_quad(&verts, &indices, {-p / 2, 0, GALLERY_POSTER_Z}, {p, 0, 0}, {0, p, 0})

	return {vertices = verts[:], indices = indices[:]}
}
