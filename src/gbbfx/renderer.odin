package gbbfx

import "core:math/linalg"
import "core:slice"
import loader "loader"
import sdl "vendor:sdl3"

Renderer :: struct {
	// Gfx owns native resources and must outlive Renderer.
	gfx:             ^Gfx,

	// Valid only between begin/end pass.
	pass:            ^sdl.GPURenderPass,
	view_projection: matrix[4, 4]f32,

	// Renderer-owned resources live for exactly the renderer lifetime.
	uploader:        Uploader,
	camera:          Camera,
	draw_items:      [dynamic]DrawItem,

	// The scene pass renders here instead of the swapchain, so post
	// processing can run before renderer_present blits to the screen.
	scene_color:     Texture_Handle,

	// Cached only during an active pass.
	bound_pipeline:  Pipeline_Handle,
	bound_material:  ^Material,
}

// Layers render in declaration order inside the pass: everything in WORLD
// draws before TRANSPARENT, TRANSPARENT before UI. Pair higher layers with
// depth-test-off pipelines when draw order must win over the depth buffer.
Render_Layer :: enum u8 {
	WORLD        = 10,
	TRANSPARENT  = 20,
	POST_PROCESS = 30,
	UI           = 40,
}

DrawItem :: struct {
	// Borrowed. Assets must outlive this item.
	mesh:      ^Mesh,
	material:  ^Material,

	// Copied because every scene instance has its own transform.
	transform: matrix[4, 4]f32,
	layer:     Render_Layer,
}

Renderer_Load_Desc :: struct {
	model_path:   string,
	texture_path: string,
	pipeline:     Pipeline_Handle,
}

renderer_create :: proc(gfx: ^Gfx) -> Renderer {
	renderer := Renderer {
		gfx    = gfx,
		camera = camera_create(
			position = Vec3{0, 0, 3},
			target = {},
			projection = linalg.matrix4_perspective(
				linalg.to_radians(f32(70)),
				gfx_aspect_ratio(gfx),
				0.1,
				1000,
			),
		),
	}
	renderer.uploader.gfx = gfx
	renderer.scene_color = gfx_texture_create_with_usage(
		gfx,
		u32(gfx.window_size.x),
		u32(gfx.window_size.y),
		sdl.GetGPUSwapchainTextureFormat(gfx.gpu, gfx.window),
		{.COLOR_TARGET, .SAMPLER},
	)
	return renderer
}

renderer_destroy :: proc(renderer: ^Renderer) {
	assert(renderer.pass == nil)
	gfx_texture_destroy(renderer.gfx, renderer.scene_color)
	uploader_destroy(&renderer.uploader)
	delete(renderer.draw_items)
	renderer^ = {}
}

renderer_load :: proc(renderer: ^Renderer, desc: Renderer_Load_Desc) -> Model {
	assert(len(desc.model_path) > 0)
	assert(Resource_Handle(desc.pipeline).generation != 0)
	imported := loader.model_import_from_obj(desc.model_path, desc.texture_path)
	defer loader.model_import_destroy(&imported)
	model := model_create(renderer.gfx, &imported, desc.pipeline)
	model_upload_to_gpu(&model, &renderer.uploader)
	return model
}

renderer_unload :: proc(renderer: ^Renderer, model: ^Model) {
	model_destroy(renderer.gfx, model)
}

renderer_begin_frame :: proc(renderer: ^Renderer) {
	_ = gfx_begin_frame(renderer.gfx)
}

renderer_end_frame :: proc(renderer: ^Renderer) {
	assert(renderer.pass == nil)
	gfx_end_frame(renderer.gfx)
}

renderer_render_scene :: proc(renderer: ^Renderer, scene: ^Scene) {
	assert(renderer.gfx.frame_open)
	if renderer.gfx.swapchain == nil do return
	for &entity in scene.entities {
		for &component in entity.components {
			#partial switch renderable in &component {
			case Renderable:
				renderer_submit(
					renderer,
					renderable.mesh,
					renderable.material,
					entity.transform,
					renderable.layer,
				)
			}
		}
	}
	renderer_begin_pass(renderer, camera_view_projection(&renderer.camera))
	renderer_flush(renderer)
	renderer_end_pass(renderer)
}

renderer_begin_pass :: proc(renderer: ^Renderer, view_projection: matrix[4, 4]f32) {
	assert(renderer.pass == nil)
	assert(renderer.gfx.command_buffer != nil)
	assert(renderer.gfx.swapchain != nil)

	color_target := sdl.GPUColorTargetInfo {
		texture     = gfx_texture_get(renderer.gfx, renderer.scene_color).handle,
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
	renderer.bound_pipeline = {}
	renderer.bound_material = nil
}

renderer_end_pass :: proc(renderer: ^Renderer) {
	assert(renderer.pass != nil)
	sdl.EndGPURenderPass(renderer.pass)
	renderer.pass = nil
	renderer.view_projection = {}
	renderer.bound_pipeline = {}
	renderer.bound_material = nil
}

// Overlay pass: a LOAD-op pass over an existing target with no depth
// attachment and identity view-projection. For UI drawn on top of the
// finished frame (pair with depth-less, blended pipelines). Close with
// renderer_end_pass.
renderer_begin_overlay_pass :: proc(renderer: ^Renderer, target: Texture_Handle) {
	assert(renderer.pass == nil)
	assert(renderer.gfx.command_buffer != nil)
	color_target := sdl.GPUColorTargetInfo {
		texture = gfx_texture_get(renderer.gfx, target).handle,
		load_op = .LOAD,
		store_op = .STORE,
	}
	renderer.pass = sdl.BeginGPURenderPass(renderer.gfx.command_buffer, &color_target, 1, nil)
	assert(renderer.pass != nil)
	renderer.view_projection = linalg.MATRIX4F32_IDENTITY
	renderer.bound_pipeline = {}
	renderer.bound_material = nil
}

// Present pass: a CLEAR pass directly on the swapchain with identity
// view-projection, for compositing the final frame (editor chrome +
// viewport) without a blit. Close with renderer_end_pass.
renderer_begin_present_pass :: proc(renderer: ^Renderer) {
	assert(renderer.pass == nil)
	assert(renderer.gfx.command_buffer != nil)
	assert(renderer.gfx.swapchain != nil)
	color_target := sdl.GPUColorTargetInfo {
		texture     = renderer.gfx.swapchain,
		load_op     = .CLEAR,
		clear_color = {0.08, 0.08, 0.1, 1},
		store_op    = .STORE,
	}
	renderer.pass = sdl.BeginGPURenderPass(renderer.gfx.command_buffer, &color_target, 1, nil)
	assert(renderer.pass != nil)
	renderer.view_projection = linalg.MATRIX4F32_IDENTITY
	renderer.bound_pipeline = {}
	renderer.bound_material = nil
}

// Blits a texture (usually the scene color or a post-processing result) onto
// the swapchain. Must run outside any pass, on the frame command buffer.
renderer_present :: proc(renderer: ^Renderer, source: Texture_Handle) {
	assert(renderer.pass == nil)
	gfx := renderer.gfx
	assert(gfx.frame_open && gfx.command_buffer != nil)
	if gfx.swapchain == nil do return
	texture := gfx_texture_get(gfx, source)
	sdl.BlitGPUTexture(
		gfx.command_buffer,
		{
			source = {texture = texture.handle, w = texture.width, h = texture.height},
			destination = {
				texture = gfx.swapchain,
				w = u32(gfx.window_size.x),
				h = u32(gfx.window_size.y),
			},
			load_op = .DONT_CARE,
			filter = .NEAREST,
		},
	)
}

renderer_draw_item :: proc(renderer: ^Renderer, item: ^DrawItem) {
	assert(renderer.pass != nil)
	assert(item.mesh != nil && item.material != nil)
	mesh := item.mesh
	material := item.material
	pipeline := gfx_pipeline_get(renderer.gfx, material.pipeline)

	if renderer.bound_pipeline != material.pipeline {
		sdl.BindGPUGraphicsPipeline(renderer.pass, pipeline.handle)
		renderer.bound_pipeline = material.pipeline
		renderer.bound_material = nil
	}
	if renderer.bound_material != material {
		gfx_pipeline_bind_material(
			renderer.gfx,
			renderer.pass,
			renderer.gfx.command_buffer,
			material,
		)
		renderer.bound_material = material
	}

	gfx_pipeline_bind_draw(
		renderer.gfx,
		material.pipeline,
		renderer.gfx.command_buffer,
		{
			view_projection = renderer.view_projection,
			model_transform = item.transform,
			material = material,
		},
	)
	mesh_draw(renderer.gfx, mesh, renderer.pass)
}

// Open submission path for scene-free experiments: call any number of times
// before gfx_render/flush, outside an active pass.
renderer_submit :: proc(
	renderer: ^Renderer,
	mesh: ^Mesh,
	material: ^Material,
	transform: matrix[4, 4]f32,
	layer: Render_Layer = .WORLD,
) {
	assert(renderer.pass == nil)
	assert(mesh != nil && material != nil)
	append_elem(
		&renderer.draw_items,
		DrawItem{mesh = mesh, material = material, transform = transform, layer = layer},
	)
}

pipeline_handle_key :: proc(handle: Pipeline_Handle) -> u64 {
	raw := Resource_Handle(handle)
	return u64(raw.generation) << 32 | u64(raw.index)
}

draw_item_less :: proc(left, right: DrawItem) -> bool {
	if left.layer != right.layer do return left.layer < right.layer
	left_pipeline := pipeline_handle_key(left.material.pipeline)
	right_pipeline := pipeline_handle_key(right.material.pipeline)
	if left_pipeline != right_pipeline do return left_pipeline < right_pipeline
	return uintptr(left.material) < uintptr(right.material)
}

// Sorting works on 16-byte (key, index) entries instead of moving whole
// DrawItems in the comparator: material pointers are mapped to small dense
// indices so the full order fits in one u64 (layer | pipeline | material).
// Thousands of items sort in microseconds instead of milliseconds.
Sort_Entry :: struct {
	key:   u64,
	index: u32,
}

sort_entry_less :: proc(left, right: Sort_Entry) -> bool {
	return left.key < right.key
}

renderer_sort_draw_items :: proc(items: []DrawItem) {
	count := len(items)
	if count < 2 do return

	unique_materials := make([dynamic]^Material, 0, 16, context.temp_allocator)
	entries := make([]Sort_Entry, count, context.temp_allocator)
	for item, index in items {
		material_index := -1
		for material, i in unique_materials {
			if material == item.material {
				material_index = i
				break
			}
		}
		if material_index < 0 {
			material_index = len(unique_materials)
			append(&unique_materials, item.material)
		}
		pipeline := pipeline_handle_key(item.material.pipeline) & 0xFFFFFFFF
		entries[index] = {
			key   = u64(item.layer) << 56 | pipeline << 24 | u64(material_index) & 0xFFFFFF,
			index = u32(index),
		}
	}
	slice.sort_by(entries, sort_entry_less)

	sorted := make([]DrawItem, count, context.temp_allocator)
	for entry, index in entries do sorted[index] = items[entry.index]
	copy(items, sorted)
}

renderer_flush :: proc(renderer: ^Renderer) {
	assert(renderer.pass != nil)
	renderer_sort_draw_items(renderer.draw_items[:])
	for &item in renderer.draw_items do renderer_draw_item(renderer, &item)
	clear(&renderer.draw_items)
}
