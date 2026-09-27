package gbbfx
import sdl "vendor:sdl3"

VertexData :: struct {
	position: [3]f32,
	color:    [4]f32,
	uv:       [2]f32,
}

// A mesh is just buffers + counts. The vertex format lives in the pipeline,
// not here, so raw geometry of any layout flows through the same type as
// loaded models. Buffers start CPU-side (see Buffer._temporary_raw_data) and
// must be pushed with mesh_upload before drawing.
Mesh :: struct {
	vertex_buffer: Buffer_Handle,
	index_buffer:  Buffer_Handle, // generation 0 = unindexed
	num_indices:   u32,
	num_vertices:  u32,
	index_size:    sdl.GPUIndexElementSize,
}

// Raw geometry seam: vertices/indices are user-built slices in whatever
// layout the bound pipeline declares (packed voxel verts included).
mesh_create :: proc(
	gfx: ^Gfx,
	vertices: []$V,
	indices: []$I,
) -> Mesh where size_of(I) == 2 || size_of(I) == 4 {
	return {
		vertex_buffer = gfx_buffer_create_from_bytes(gfx, vertices, .VERTEX),
		index_buffer = gfx_buffer_create_from_bytes(gfx, indices, .INDEX),
		num_indices = u32(len(indices)),
		num_vertices = u32(len(vertices)),
		index_size = size_of(I) == 2 ? ._16BIT : ._32BIT,
	}
}

mesh_create_unindexed :: proc(gfx: ^Gfx, vertices: []$V) -> Mesh {
	return {
		vertex_buffer = gfx_buffer_create_from_bytes(gfx, vertices, .VERTEX),
		num_vertices = u32(len(vertices)),
	}
}

// Replaces the mesh contents and re-uploads. Buffers are reused while they
// are large enough and grown (with a GPU idle wait) when they are not, so
// this is safe to call every frame. Upload is blocking; call outside an
// active pass, e.g. in the tick before gfx_render.
mesh_update :: proc(
	renderer: ^Renderer,
	mesh: ^Mesh,
	vertices: []$V,
	indices: []$I,
) where size_of(I) == 2 || size_of(I) == 4 {
	assert(len(vertices) > 0 && len(indices) > 0)
	mesh.vertex_buffer = gfx_buffer_stage(renderer.gfx, mesh.vertex_buffer, vertices, .VERTEX)
	mesh.index_buffer = gfx_buffer_stage(renderer.gfx, mesh.index_buffer, indices, .INDEX)
	mesh.num_vertices = u32(len(vertices))
	mesh.num_indices = u32(len(indices))
	mesh.index_size = size_of(I) == 2 ? ._16BIT : ._32BIT
	mesh_upload(renderer, mesh)
}

mesh_update_unindexed :: proc(renderer: ^Renderer, mesh: ^Mesh, vertices: []$V) {
	assert(len(vertices) > 0)
	mesh.vertex_buffer = gfx_buffer_stage(renderer.gfx, mesh.vertex_buffer, vertices, .VERTEX)
	mesh.num_vertices = u32(len(vertices))
	mesh_upload(renderer, mesh)
}

mesh_upload :: proc(renderer: ^Renderer, mesh: ^Mesh) {
	uploader_begin(&renderer.uploader)
	uploader_upload_buffer(&renderer.uploader, mesh.vertex_buffer)
	if Resource_Handle(mesh.index_buffer).generation != 0 {
		uploader_upload_buffer(&renderer.uploader, mesh.index_buffer)
	}
	uploader_flush_blocking(&renderer.uploader)
	gfx_buffer_get(renderer.gfx, mesh.vertex_buffer)._temporary_raw_data = nil
	if Resource_Handle(mesh.index_buffer).generation != 0 {
		gfx_buffer_get(renderer.gfx, mesh.index_buffer)._temporary_raw_data = nil
	}
}

mesh_draw :: proc(gfx: ^Gfx, mesh: ^Mesh, render_pass: ^sdl.GPURenderPass) {
	vertex_buffer := gfx_buffer_get(gfx, mesh.vertex_buffer)
	sdl.BindGPUVertexBuffers(
		render_pass,
		0,
		&(sdl.GPUBufferBinding{buffer = vertex_buffer.handle}),
		1,
	)
	if Resource_Handle(mesh.index_buffer).generation != 0 {
		index_buffer := gfx_buffer_get(gfx, mesh.index_buffer)
		sdl.BindGPUIndexBuffer(render_pass, {buffer = index_buffer.handle}, mesh.index_size)
		sdl.DrawGPUIndexedPrimitives(render_pass, mesh.num_indices, 1, 0, 0, 0)
	} else {
		sdl.DrawGPUPrimitives(render_pass, mesh.num_vertices, 1, 0, 0)
	}
}

mesh_destroy :: proc(gfx: ^Gfx, mesh: ^Mesh) {
	gfx_buffer_destroy(gfx, mesh.vertex_buffer)
	gfx_buffer_destroy(gfx, mesh.index_buffer)
	mesh^ = {}
}
