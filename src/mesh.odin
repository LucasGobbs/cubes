package main
import sdl "vendor:sdl3"

VertexData :: struct {
	position: [3]f32,
	color:    [4]f32,
	uv:       [2]f32,
}

VertexLayout :: enum {
	POS_COLOR_UV,
}

Mesh :: struct {
	vertex_buffer: Buffer_Handle,
	index_buffer:  Buffer_Handle,
	num_indices:   u32,
	index_size:    sdl.GPUIndexElementSize,
	layout:        VertexLayout,
}

mesh_draw :: proc(gfx: ^Gfx, mesh: ^Mesh, render_pass: ^sdl.GPURenderPass) {
	vertex_buffer := gfx_buffer_get(gfx, mesh.vertex_buffer)
	index_buffer := gfx_buffer_get(gfx, mesh.index_buffer)
	sdl.BindGPUVertexBuffers(
		render_pass,
		0,
		&(sdl.GPUBufferBinding{buffer = vertex_buffer.handle}),
		1,
	)
	sdl.BindGPUIndexBuffer(render_pass, {buffer = index_buffer.handle}, mesh.index_size)
	sdl.DrawGPUIndexedPrimitives(render_pass, mesh.num_indices, 1, 0, 0, 0)
}

mesh_destroy :: proc(gfx: ^Gfx, mesh: ^Mesh) {
	gfx_buffer_destroy(gfx, mesh.vertex_buffer)
	gfx_buffer_destroy(gfx, mesh.index_buffer)
	mesh^ = {}
}
