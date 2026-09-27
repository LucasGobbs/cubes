package main

import sdl "vendor:sdl3"

Renderer :: struct {
	// Borrowed. Gfx must outlive Renderer.
	gfx:             ^Gfx,

	// Valid only between begin/end pass.
	pass:            ^sdl.GPURenderPass,
	view_projection: matrix[4, 4]f32,

	// Owned by Renderer.
	basic_pipeline:  Pipeline,
	default_sampler: ^sdl.GPUSampler,
	draw_items:      [dynamic]DrawItem,
}

DrawItem :: struct {
	// Borrowed. Model assets must outlive this item.
	mesh:      ^Mesh,
	material:  ^Material,

	// Copied because every scene instance has its own transform.
	transform: matrix[4, 4]f32,
}


renderer_init :: proc(gfx: ^Gfx) -> Renderer {
	pipeline := gfx_basic_pipeline(gfx)
	sampler := sdl.CreateGPUSampler(gfx.gpu, {})

	assert(pipeline.handle != nil)
	assert(sampler != nil)

	return {gfx = gfx, basic_pipeline = pipeline, default_sampler = sampler}
}

renderer_destroy :: proc(renderer: ^Renderer) {
	// Destroying during an active pass would invalidate recorded state.
	assert(renderer.pass == nil)

	sdl.ReleaseGPUSampler(renderer.gfx.gpu, renderer.default_sampler)
	sdl.ReleaseGPUGraphicsPipeline(renderer.gfx.gpu, renderer.basic_pipeline.handle)
	delete(renderer.draw_items)
	renderer^ = {}
}

renderer_begin_pass :: proc(renderer: ^Renderer, view_projection: matrix[4, 4]f32) {
	assert(renderer.pass == nil)
	assert(renderer.gfx.command_buffer != nil)
	assert(renderer.gfx.swapchain != nil)

	color_target := sdl.GPUColorTargetInfo {
		texture     = renderer.gfx.swapchain,
		load_op     = .CLEAR,
		clear_color = {0.2, 0.2, 0.5, 1},
		store_op    = .STORE,
	}

	depth_target := sdl.GPUDepthStencilTargetInfo {
		texture     = renderer.gfx.depth_texture,
		load_op     = .CLEAR,
		clear_depth = 1,
		store_op    = .DONT_CARE,
	}

	renderer.pass = sdl.BeginGPURenderPass(
		renderer.gfx.command_buffer,
		&color_target,
		1,
		&depth_target,
	)
	assert(renderer.pass != nil)
	renderer.view_projection = view_projection
}

renderer_end_pass :: proc(renderer: ^Renderer) {
	assert(renderer.pass != nil)

	sdl.EndGPURenderPass(renderer.pass)
	renderer.pass = nil
	renderer.view_projection = {}
}

renderer_draw_item :: proc(renderer: ^Renderer, item: ^DrawItem) {
	assert(renderer.pass != nil)
	assert(item.mesh != nil)
	assert(item.material != nil)

	mesh := item.mesh
	material := item.material

	assert(material.pipeline != nil && material.pipeline.handle != nil)
	assert(material.sampler != nil)
	assert(material.texture.handle != nil)
	assert(mesh.vertex_buffer.handle != nil)
	assert(mesh.index_buffer.handle != nil)

	sdl.BindGPUGraphicsPipeline(renderer.pass, material.pipeline.handle)
	sdl.BindGPUFragmentSamplers(
		renderer.pass,
		0,
		&(sdl.GPUTextureSamplerBinding {
				texture = material.texture.handle,
				sampler = material.sampler,
			}),
		1,
	)

	pipeline_bind_draw(
		material.pipeline,
		renderer.gfx.command_buffer,
		{view_projection = renderer.view_projection, model_transform = item.transform},
	)

	sdl.BindGPUVertexBuffers(
		renderer.pass,
		0,
		&(sdl.GPUBufferBinding{buffer = mesh.vertex_buffer.handle}),
		1,
	)
	sdl.BindGPUIndexBuffer(renderer.pass, {buffer = mesh.index_buffer.handle}, mesh.index_size)
	sdl.DrawGPUIndexedPrimitives(renderer.pass, mesh.num_indices, 1, 0, 0, 0)
}

renderer_draw_model :: proc(renderer: ^Renderer, model: ^Model, transform: matrix[4, 4]f32) {
	assert(model != nil)

	item := DrawItem {
		mesh      = &model.mesh,
		material  = &model.material,
		transform = transform,
	}
	renderer_draw_item(renderer, &item)
}

renderer_submit_model :: proc(renderer: ^Renderer, model: ^Model, transform: matrix[4, 4]f32) {
	assert(renderer.pass == nil)
	assert(model != nil)

	append_elem(
		&renderer.draw_items,
		DrawItem{mesh = &model.mesh, material = &model.material, transform = transform},
	)
}
renderer_flush :: proc(renderer: ^Renderer) {
	assert(renderer.pass != nil)
	for &item in renderer.draw_items {
		renderer_draw_item(renderer, &item)
	}

	clear(&renderer.draw_items)
}
