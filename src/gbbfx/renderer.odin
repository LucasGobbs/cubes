package gbbfx

import "core:math/linalg"
import "core:mem"
import "core:slice"
import loader "loader"
import sdl "vendor:sdl3"

// Sample count of the MSAA mode (4x is supported by every SDL GPU backend).
MSAA_SAMPLES :: sdl.GPUSampleCount._4

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
	// Always 1x: with MSAA on it is the resolve target, so everything that
	// reads the scene (blur, overlay, present) is unaffected by MSAA.
	scene_color:     Texture_Handle,
	// Depth buffer matching scene_color's size and sample count. Reverse-Z:
	// cleared to 0 (far), pipelines compare GREATER (see camera_perspective).
	// Resize all targets together with renderer_resize_targets.
	scene_depth:     Texture_Handle,
	// MSAA: scene pass renders into scene_color_msaa (generation 0 when off)
	// and resolves into scene_color. Toggle with renderer_set_msaa.
	scene_color_msaa: Texture_Handle,
	msaa_enabled:    bool,
	msaa_supported:  bool, // device can do MSAA_SAMPLES for color and depth

	// Instancing: per-frame transform storage for instanced runs, uploaded
	// between prepare and the pass. offsets are indexed by draw item.
	// previous is a copy of the last uploaded transforms; prepare skips the
	// upload (and its GPU stall) when nothing changed.
	instance_buffer: Buffer_Handle,
	instance_transforms: [dynamic]matrix[4, 4]f32,
	instance_offsets:    [dynamic]u32,
	instance_previous:   [dynamic]matrix[4, 4]f32,

	// Number of GPU draws issued in the last flush (HUD/profiling).
	draw_calls:      int,

	// Cached only during an active pass.
	bound_pipeline:  Pipeline_Handle,
	bound_material:  ^Material,
	pass_msaa:       bool, // the open pass is multisampled
}

// Layers render in declaration order inside the pass: everything in WORLD
// draws before SKYBOX, SKYBOX before TRANSPARENT, TRANSPARENT before UI. The
// skybox draws after opaque geometry so the depth test skips covered pixels.
// Pair higher layers with depth-test-off pipelines when draw order must win
// over the depth buffer.
Render_Layer :: enum u8 {
	WORLD        = 10,
	SKYBOX       = 15,
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
	// .glb/.gltf; the base color texture comes from the file.
	model_path: string,
	pipeline:   Pipeline_Handle,
}

renderer_create :: proc(gfx: ^Gfx) -> Renderer {
	renderer := Renderer {
		gfx    = gfx,
		camera = camera_create(
			position = Vec3{0, 0, 3},
			target = {},
			projection = camera_perspective(gfx_aspect_ratio(gfx)),
		),
	}
	renderer.uploader.gfx = gfx
	renderer.instance_buffer = gfx_buffer_create(
		gfx,
		u32(64 * size_of(matrix[4, 4]f32)),
		.GRAPHICS_STORAGE_READ,
	)
	renderer.scene_color = gfx_texture_create_with_usage(
		gfx,
		u32(gfx.window_size.x),
		u32(gfx.window_size.y),
		sdl.GetGPUSwapchainTextureFormat(gfx.gpu, gfx.window),
		{.COLOR_TARGET, .SAMPLER},
	)
	renderer.scene_depth = gfx_texture_create_with_usage(
		gfx,
		u32(gfx.window_size.x),
		u32(gfx.window_size.y),
		.D32_FLOAT,
		{.DEPTH_STENCIL_TARGET},
	)
	color_format := sdl.GetGPUSwapchainTextureFormat(gfx.gpu, gfx.window)
	renderer.msaa_supported =
		sdl.GPUTextureSupportsSampleCount(gfx.gpu, color_format, MSAA_SAMPLES) &&
		sdl.GPUTextureSupportsSampleCount(gfx.gpu, .D32_FLOAT, MSAA_SAMPLES)
	return renderer
}

// Turns MSAA on or off by rebuilding the scene depth (and the multisampled
// color target). Returns the resulting state: false when asked to enable on a
// device without support. Waits for GPU idle; call between frames, outside a
// pass. Pipelines need no rebuild: each carries both variants.
renderer_set_msaa :: proc(renderer: ^Renderer, enabled: bool) -> bool {
	assert(renderer.pass == nil)
	enabled := enabled && renderer.msaa_supported
	if enabled == renderer.msaa_enabled do return enabled

	gfx := renderer.gfx
	_ = sdl.WaitForGPUIdle(gfx.gpu)
	size := gfx_texture_get(gfx, renderer.scene_color)
	width, height := size.width, size.height
	gfx_texture_destroy(gfx, renderer.scene_depth)
	gfx_texture_destroy(gfx, renderer.scene_color_msaa)
	renderer.scene_color_msaa = {}

	samples := MSAA_SAMPLES if enabled else sdl.GPUSampleCount._1
	renderer.scene_depth = gfx_texture_create_with_usage(
		gfx,
		width,
		height,
		.D32_FLOAT,
		{.DEPTH_STENCIL_TARGET},
		samples,
	)
	if enabled {
		renderer.scene_color_msaa = gfx_texture_create_with_usage(
			gfx,
			width,
			height,
			size.format,
			{.COLOR_TARGET},
			samples,
		)
	}
	renderer.msaa_enabled = enabled
	return enabled
}

renderer_destroy :: proc(renderer: ^Renderer) {
	assert(renderer.pass == nil)
	gfx_buffer_destroy(renderer.gfx, renderer.instance_buffer)
	delete(renderer.instance_transforms)
	delete(renderer.instance_offsets)
	delete(renderer.instance_previous)
	gfx_texture_destroy(renderer.gfx, renderer.scene_color)
	gfx_texture_destroy(renderer.gfx, renderer.scene_depth)
	gfx_texture_destroy(renderer.gfx, renderer.scene_color_msaa)
	uploader_destroy(&renderer.uploader)
	delete(renderer.draw_items)
	renderer^ = {}
}

// Resizes the scene color, depth and MSAA color targets together (they must match).
// Waits for GPU idle; call between frames.
renderer_resize_targets :: proc(renderer: ^Renderer, width, height: u32) {
	gfx_texture_resize(renderer.gfx, &renderer.scene_color, width, height)
	gfx_texture_resize(renderer.gfx, &renderer.scene_depth, width, height)
	if renderer.msaa_enabled {
		gfx_texture_resize(renderer.gfx, &renderer.scene_color_msaa, width, height)
	}
}

renderer_load :: proc(renderer: ^Renderer, desc: Renderer_Load_Desc) -> Model {
	assert(len(desc.model_path) > 0)
	assert(Resource_Handle(desc.pipeline).generation != 0)
	imported, ok := loader.model_import_from_gltf(desc.model_path)
	assert(ok, "renderer_load: model import failed")
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
	renderer_prepare(renderer)
	renderer_begin_pass(renderer, camera_view_projection(&renderer.camera))
	renderer_flush(renderer)
	renderer_end_pass(renderer)
}

// Sorts the frame's draw items, gathers per-instance transforms for
// instanced pipelines, and uploads them — all before the pass opens, since
// the upload submits its own command buffer.
renderer_prepare :: proc(renderer: ^Renderer) {
	renderer_sort_draw_items(renderer.draw_items[:])
	clear(&renderer.instance_transforms)
	clear(&renderer.instance_offsets)
	renderer.draw_calls = 0
	for item in renderer.draw_items {
		pipeline := gfx_pipeline_get(renderer.gfx, item.material.pipeline)
		if pipeline.instanced {
			append(&renderer.instance_offsets, u32(len(renderer.instance_transforms)))
			append(&renderer.instance_transforms, item.transform)
		} else {
			append(&renderer.instance_offsets, 0)
		}
	}
	if len(renderer.instance_transforms) == 0 do return
	current := slice.to_bytes(renderer.instance_transforms[:])
	if len(renderer.instance_transforms) == len(renderer.instance_previous) &&
	   mem.compare(current, slice.to_bytes(renderer.instance_previous[:])) == 0 {
		return // static scene: the buffer on the GPU is already correct
	}
	clear(&renderer.instance_previous)
	append(&renderer.instance_previous, ..renderer.instance_transforms[:])
	renderer.instance_buffer = gfx_buffer_stage(
		renderer.gfx,
		renderer.instance_buffer,
		renderer.instance_transforms[:],
		.GRAPHICS_STORAGE_READ,
	)
	uploader_begin(&renderer.uploader)
	uploader_upload_buffer(&renderer.uploader, renderer.instance_buffer)
	uploader_flush_blocking(&renderer.uploader)
	gfx_buffer_get(renderer.gfx, renderer.instance_buffer)._temporary_raw_data = nil
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
	if renderer.msaa_enabled {
		// Draw into the multisampled texture; at pass end the samples are
		// averaged into scene_color and the multisampled data is dropped.
		color_target.resolve_texture = color_target.texture
		color_target.texture = gfx_texture_get(renderer.gfx, renderer.scene_color_msaa).handle
		color_target.store_op = .RESOLVE
	}
	depth_target := sdl.GPUDepthStencilTargetInfo {
		texture     = gfx_texture_get(renderer.gfx, renderer.scene_depth).handle,
		load_op     = .CLEAR,
		clear_depth = 0, // reverse-Z: 0 is the far plane
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
	renderer.pass_msaa = renderer.msaa_enabled
	renderer.bound_pipeline = {}
	renderer.bound_material = nil
}

renderer_end_pass :: proc(renderer: ^Renderer) {
	assert(renderer.pass != nil)
	sdl.EndGPURenderPass(renderer.pass)
	renderer.pass = nil
	renderer.pass_msaa = false // overlay/present passes are always 1x
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
		sdl.BindGPUGraphicsPipeline(renderer.pass, pipeline_native(pipeline, renderer.pass_msaa))
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
	renderer.draw_calls += 1
}

// One instanced draw for a run of items sharing mesh and material. The
// shader reads transforms from the instance storage buffer at
// SV_InstanceID = first_instance + i.
renderer_draw_instanced_run :: proc(
	renderer: ^Renderer,
	item: ^DrawItem,
	count: int,
	first_instance: u32,
) {
	assert(renderer.pass != nil)
	mesh := item.mesh
	material := item.material
	pipeline := gfx_pipeline_get(renderer.gfx, material.pipeline)

	if renderer.bound_pipeline != material.pipeline {
		sdl.BindGPUGraphicsPipeline(renderer.pass, pipeline_native(pipeline, renderer.pass_msaa))
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
			model_transform = {},
			material = material,
			first_instance = first_instance,
		},
	)
	mesh_draw_instanced(renderer.gfx, mesh, renderer.pass, u32(count), 0)
	renderer.draw_calls += 1
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
	renderer_radix_sort(entries)

	sorted := make([]DrawItem, count, context.temp_allocator)
	for entry, index in entries do sorted[index] = items[entry.index]
	copy(items, sorted)
}

// LSD radix over the 64-bit key: 8 stable counting passes, O(n) — a
// comparison sort becomes the CPU wall around 100k draw items.
renderer_radix_sort :: proc(entries: []Sort_Entry) {
	count := len(entries)
	if count < 2 do return
	// Temp arena: freed by the frame's free_all, never delete()d.
	scratch := make([]Sort_Entry, count, context.temp_allocator)
	source := entries
	destination := scratch
	for pass in 0 ..< 8 {
		shift := u64(pass * 8)
		buckets: [256]int
		for entry in source do buckets[(entry.key >> shift) & 0xFF] += 1
		total := 0
		for &bucket in buckets {
			bucket, total = total, total + bucket
		}
		for entry in source {
			digit := (entry.key >> shift) & 0xFF
			destination[buckets[digit]] = entry
			buckets[digit] += 1
		}
		source, destination = destination, source
	}
	if raw_data(source) != raw_data(entries) do copy(entries, source)
}

renderer_flush :: proc(renderer: ^Renderer) {
	assert(renderer.pass != nil)
	if len(renderer.instance_transforms) > 0 {
		instance_buffer := gfx_buffer_get(renderer.gfx, renderer.instance_buffer)
		sdl.BindGPUVertexStorageBuffers(renderer.pass, 0, &(instance_buffer.handle), 1)
	}
	index := 0
	for index < len(renderer.draw_items) {
		item := &renderer.draw_items[index]
		pipeline := gfx_pipeline_get(renderer.gfx, item.material.pipeline)
		if !pipeline.instanced {
			renderer_draw_item(renderer, item)
			index += 1
			continue
		}
		run_end := index + 1
		for run_end < len(renderer.draw_items) {
			other := &renderer.draw_items[run_end]
			if other.mesh != item.mesh || other.material != item.material do break
			run_end += 1
		}
		renderer_draw_instanced_run(
			renderer,
			item,
			run_end - index,
			renderer.instance_offsets[index],
		)
		index = run_end
	}
	clear(&renderer.draw_items)
}
