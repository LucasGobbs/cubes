// CPU triangle builder for city geometry. Faces wind CCW seen from outside, so BACK culling keeps the outside;
// normals come from the winding.
package city

import gfx "../../engine/gfx"
import "core:math/linalg"

Vec3 :: gfx.Vec3

Mesh_Builder :: struct {
	vertices: [dynamic]gfx.VertexData,
	indices:  [dynamic]u32,
}

builder_destroy :: proc(b: ^Mesh_Builder) {
	delete(b.vertices)
	delete(b.indices)
	b^ = {}
}

// Slices alias the builder: valid until builder_destroy or the next append.
builder_to_mesh_data :: proc(b: ^Mesh_Builder) -> gfx.Mesh_Data {
	return {vertices = b.vertices[:], indices = b.indices[:]}
}

// p0..p3 CCW from outside. uv0 is the uv at p0 and uv1 the uv at p2: the uv rectangle maps axis-aligned onto the quad.
builder_quad :: proc(b: ^Mesh_Builder, p0, p1, p2, p3: Vec3, uv0, uv1: [2]f32, color: [4]f32) {
	normal := linalg.normalize(linalg.cross(p1 - p0, p3 - p0))
	base := u32(len(b.vertices))
	append(
		&b.vertices,
		gfx.VertexData{position = p0, color = color, uv = {uv0.x, uv0.y}, normal = normal},
		gfx.VertexData{position = p1, color = color, uv = {uv1.x, uv0.y}, normal = normal},
		gfx.VertexData{position = p2, color = color, uv = {uv1.x, uv1.y}, normal = normal},
		gfx.VertexData{position = p3, color = color, uv = {uv0.x, uv1.y}, normal = normal},
	)
	append(&b.indices, base, base + 1, base + 2, base, base + 2, base + 3)
}

// Triangle CCW from outside; uv is zero, so use it for untextured faces only.
builder_tri :: proc(b: ^Mesh_Builder, p0, p1, p2: Vec3, color: [4]f32) {
	normal := linalg.normalize(linalg.cross(p1 - p0, p2 - p0))
	base := u32(len(b.vertices))
	append(
		&b.vertices,
		gfx.VertexData{position = p0, color = color, normal = normal},
		gfx.VertexData{position = p1, color = color, normal = normal},
		gfx.VertexData{position = p2, color = color, normal = normal},
	)
	append(&b.indices, base, base + 1, base + 2)
}
