package main
import sdl "vendor:sdl3"

VertexLayout :: enum {
	POS_COLOR_UV, /* later: POS_NORMAL_UV, ... */
}
Mesh :: struct {
	vertex_buffer: Buffer,
	index_buffer:  Buffer,
	num_indices:   u32,
	index_size:    sdl.GPUIndexElementSize,
	layout:        VertexLayout,
}

mesh_draw :: proc(mesh: ^Mesh, render_pass: ^sdl.GPURenderPass) {
	sdl.BindGPUVertexBuffers(
		render_pass,
		0,
		&(sdl.GPUBufferBinding{buffer = mesh.vertex_buffer.handle}),
		1,
	)
	sdl.BindGPUIndexBuffer(render_pass, {buffer = mesh.index_buffer.handle}, ._16BIT)
	sdl.DrawGPUIndexedPrimitives(render_pass, u32(mesh.num_indices), 1, 0, 0, 0)
}
