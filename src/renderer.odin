package main

import "core:math/linalg"
import loader "loader"
import sdl "vendor:sdl3"

Renderer :: struct {
	// Gfx owns native resources and must outlive Renderer.
	gfx:               ^Gfx,

	// Valid only between begin/end pass.
	pass:              ^sdl.GPURenderPass,
	view_projection:   matrix[4, 4]f32,

	// Renderer-owned resources live for exactly the renderer lifetime.
	textured_pipeline: Pipeline_Handle,
	unlit_pipeline:    Pipeline_Handle,
	default_sampler:   Sampler_Handle,
	uploader:          Uploader,
	camera:            Camera,
	draw_items:        [dynamic]DrawItem,

	// Cached only during an active pass.
	bound_pipeline:    Pipeline_Handle,
	bound_material:    ^Material,
}

DrawItem :: struct {
	// Borrowed. Model assets must outlive this item.
	mesh:      ^Mesh,
	material:  ^Material,

	// Copied because every scene instance has its own transform.
	transform: matrix[4, 4]f32,
}

Renderer_Load_Desc :: struct {
	model_path:   string,
	texture_path: string,
	unlit_tint:   [4]f32,
}

Renderer_Assets :: struct {
	textured_model: Model,
	unlit_model:    Model,
}

renderer_create :: proc(gfx: ^Gfx) -> Renderer {
	renderer := Renderer {
		gfx               = gfx,
		textured_pipeline = gfx_pipeline_create_textured(gfx),
		unlit_pipeline    = gfx_pipeline_create_unlit(gfx),
		default_sampler   = gfx_sampler_create(gfx),
		camera            = camera_create(
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
	return renderer
}

renderer_destroy :: proc(renderer: ^Renderer) {
	assert(renderer.pass == nil)
	uploader_destroy(&renderer.uploader)
	gfx_sampler_destroy(renderer.gfx, renderer.default_sampler)
	gfx_pipeline_destroy(renderer.gfx, renderer.textured_pipeline)
	gfx_pipeline_destroy(renderer.gfx, renderer.unlit_pipeline)
	delete(renderer.draw_items)
	renderer^ = {}
}

renderer_load :: proc(renderer: ^Renderer, desc: Renderer_Load_Desc) -> Renderer_Assets {
	assert(len(desc.model_path) > 0 && len(desc.texture_path) > 0)
	imported := loader.model_import_from_obj(desc.model_path, desc.texture_path)
	defer loader.model_import_destroy(&imported)
	return {
		textured_model = renderer_create_textured_model(renderer, &imported),
		unlit_model = renderer_create_unlit_model(renderer, &imported, desc.unlit_tint),
	}
}

renderer_unload :: proc(renderer: ^Renderer, assets: ^Renderer_Assets) {
	renderer_destroy_model(renderer, &assets.textured_model)
	renderer_destroy_model(renderer, &assets.unlit_model)
	assets^ = {}
}

renderer_create_textured_model :: proc(
	renderer: ^Renderer,
	imported: ^loader.ImportedModel,
) -> Model {
	model := model_create_textured(
		renderer.gfx,
		imported,
		renderer.default_sampler,
		renderer.textured_pipeline,
	)
	model_upload_to_gpu(&model, &renderer.uploader)
	return model
}

renderer_create_unlit_model :: proc(
	renderer: ^Renderer,
	imported: ^loader.ImportedModel,
	tint: [4]f32,
) -> Model {
	model := model_create_unlit(renderer.gfx, imported, renderer.unlit_pipeline, tint)
	model_upload_to_gpu(&model, &renderer.uploader)
	return model
}

renderer_destroy_model :: proc(renderer: ^Renderer, model: ^Model) {
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
	for &node in scene.nodes do renderer_submit_model(renderer, node.model, node.transform)
	renderer_begin_pass(renderer, camera_view_projection(&renderer.camera))
	renderer_flush(renderer)
	renderer_end_pass(renderer)
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
			material.pipeline,
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

pipeline_handle_key :: proc(handle: Pipeline_Handle) -> u64 {
	raw := Resource_Handle(handle)
	return u64(raw.generation) << 32 | u64(raw.index)
}

draw_item_less :: proc(left, right: DrawItem) -> bool {
	left_pipeline := pipeline_handle_key(left.material.pipeline)
	right_pipeline := pipeline_handle_key(right.material.pipeline)
	if left_pipeline != right_pipeline do return left_pipeline < right_pipeline
	return uintptr(left.material) < uintptr(right.material)
}

renderer_sort_draw_items :: proc(items: []DrawItem) {
	for index in 1 ..< len(items) {
		for cursor := index;
		    cursor > 0 && draw_item_less(items[cursor], items[cursor - 1]);
		    cursor -= 1 {
			temporary := items[cursor]
			items[cursor] = items[cursor - 1]
			items[cursor - 1] = temporary
		}
	}
}

renderer_flush :: proc(renderer: ^Renderer) {
	assert(renderer.pass != nil)
	renderer_sort_draw_items(renderer.draw_items[:])
	for &item in renderer.draw_items do renderer_draw_item(renderer, &item)
	clear(&renderer.draw_items)
}
