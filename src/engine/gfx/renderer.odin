package gfx

import "core:math/linalg"
import "core:math"
import "core:log"
import "core:mem"
import "core:slice"
import "core:time"
import "../jobs"
import loader "loader"
import sdl "vendor:sdl3"

// Sample count of the MSAA mode (4x is supported by every SDL GPU backend).
MSAA_SAMPLES :: sdl.GPUSampleCount._4
// Draw instanced runs through DrawGPUIndexedPrimitivesIndirect (--indirect). Same output as the direct path.
indirect_draws := false

// Skinned instances per frame; each owns MAX_JOINTS palette matrices.
MAX_SKINNED_INSTANCES :: 64

// Sun shadow map: square texels, box side and light-space depth range in world units.
SHADOW_MAP_SIZE :: 2048
SHADOW_EXTENT :: 120
SHADOW_DEPTH :: 300
// Light direction restored when a scene that set its own sun is destroyed.
DEFAULT_LIGHT_DIRECTION :: [3]f32{0.4, 1.0, 0.6}

Renderer :: struct {
	// Device owns native resources and must outlive Renderer.
	gfx_ctx:         ^Device,

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
	// Format of scene_depth and of every depth pipeline drawn in the scene pass. Chosen once at create.
	scene_depth_format: sdl.GPUTextureFormat,
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
	// One command per non-skinned instanced run, in draw order; first_instance stays 0 (SDL: incompatible with SV_InstanceID).
	indirect_buffer:     Buffer_Handle,
	indirect_commands:   [dynamic]sdl.GPUIndexedIndirectDrawCommand,
	indirect_previous:   [dynamic]sdl.GPUIndexedIndirectDrawCommand,
	indirect_cursor:     int,

	// Skinned instances use their own arrays: palette index is
	// (instance + first_instance) * MAX_JOINTS, so they cannot share the static
	// indexing. Palettes animate every frame, so they upload unconditionally.
	skinned_buffer:     Buffer_Handle,
	palette_buffer:     Buffer_Handle,
	skinned_transforms: [dynamic]matrix[4, 4]f32,
	palettes:           [dynamic]matrix[4, 4]f32,

	// Number of GPU draws issued in the last flush (HUD/profiling).
	draw_calls:      int,
	// Set once the skinned cap was exceeded; the error is logged a single time.
	skinned_overflow_logged: bool,
	// GPU triangles submitted in the last flush.
	triangles:       int,
	// Last flush: instanced draws, instances they drew, pipeline and material binds.
	instanced_draws: int,
	instance_count:  int,
	pipeline_binds:  int,
	material_binds:  int,
	// Linear rgb fog color + view distance (a <= 0 = off). Set per frame by the scene.
	fog:             [4]f32,
	// sRGB clear color of the scene pass; converted to linear when cleared.
	clear_color:     [4]f32,
	// CPU time of the last frame's prepare and flush (benchmark mode reads these).
	prepare_time:    time.Duration,
	flush_time:      time.Duration,
	extract_time:    time.Duration,
	shadow_time:     time.Duration,
	// Worker pool for parallel extract; nil = serial. Borrowed from the host.
	jobs:            ^jobs.Pool,

	// Cached only during an active pass.
	bound_pipeline:  Pipeline_Handle,
	bound_material:  ^Material,
	pass_msaa:       bool, // the open pass is multisampled

	// Post-processing: passes per slot (rgraph.odin), transient textures from the pool.
	passes:          [Pass_Slot][dynamic]Render_Pass,
	pool:            Texture_Pool,
	post_sampler:    Sampler_Handle,
	post_format:     sdl.GPUTextureFormat,
	// Frame capture for offline rendering (readback.odin).
	readback:        Readback,
	// Scene hooks run in registration order around the scene pass (see Scene_Hook).
	scene_hooks:     [dynamic]Scene_Hook,
	// Sun shadow map: depth-only pass before the scene pass (renderer_draw_shadow).
	// Conventional Z (clear 1, LESS), not reverse-Z. light_direction is unit, toward the light.
	shadow_enabled:            bool,
	shadow_map:                Texture_Handle, // D32_FLOAT, SHADOW_MAP_SIZE^2, sampled later
	shadow_sampler:            Sampler_Handle, // comparison sampler for the scene pass
	shadow_pipeline:           Pipeline_Handle,
	shadow_instanced_pipeline: Pipeline_Handle,
	light_direction:           [3]f32,
	light_view_projection:     matrix[4, 4]f32,
}

// Engine systems hook the frame around the scene pass (see renderer_draw_submitted).
Scene_Hook :: struct {
	name:   string,
	// Runs outside any pass with the frame command buffer open: compute dispatch and uploader work allowed.
	before: proc(renderer: ^Renderer, user: rawptr),
	// Runs inside the scene pass after all draw items: renderer.pass and renderer.view_projection are valid, depth is testable.
	draw:   proc(renderer: ^Renderer, user: rawptr),
	// Borrowed: the owner keeps it alive while registered. Either proc may be nil.
	user:   rawptr,
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
	// Skinned items only: the pose sampled for this instance (borrowed).
	pose:      ^Pose,
	// Off-screen shadow caster: sorted after the visible items of its (mesh, material) run;
	// the main pass skips it, the shadow pass draws it.
	shadow_only: bool,
}

Renderer_Load_Desc :: struct {
	// .glb/.gltf; the base color texture comes from the file.
	model_path: string,
	pipeline:   Pipeline_Handle,
}
// sRGB clear color of the scene pass until a scene sets its own.
DEFAULT_CLEAR_COLOR :: [4]f32{0.2, 0.2, 0.5, 1}

// Combined depth+stencil format for the scene pass. D32 float first keeps the precision reverse-Z relies on.
pick_depth_stencil_format :: proc(gpu: ^sdl.GPUDevice) -> sdl.GPUTextureFormat {
	for format in ([?]sdl.GPUTextureFormat{.D32_FLOAT_S8_UINT, .D24_UNORM_S8_UINT}) {
		if sdl.GPUTextureSupportsFormat(gpu, format, .D2, {.DEPTH_STENCIL_TARGET}) do return format
	}
	assert(false, "no depth+stencil texture format supported")
	return .INVALID
}

renderer_create :: proc(gfx_ctx: ^Device) -> Renderer {
	renderer := Renderer {
		gfx_ctx     = gfx_ctx,
		clear_color = DEFAULT_CLEAR_COLOR,
		camera = camera_create(
			position = Vec3{0, 0, 3},
			target = {},
			projection = camera_perspective(aspect_ratio(gfx_ctx)),
		),
	}
	renderer.uploader.gfx_ctx = gfx_ctx
	renderer.instance_buffer = buffer_create(
		gfx_ctx,
		u32(64 * size_of(matrix[4, 4]f32)),
		.GRAPHICS_STORAGE_READ,
	)
	renderer.indirect_buffer = buffer_create(gfx_ctx, u32(16 * size_of(sdl.GPUIndexedIndirectDrawCommand)), .INDIRECT)
	renderer.skinned_buffer = buffer_create(
		gfx_ctx,
		u32(MAX_SKINNED_INSTANCES * size_of(matrix[4, 4]f32)),
		.GRAPHICS_STORAGE_READ,
	)
	renderer.palette_buffer = buffer_create(
		gfx_ctx,
		u32(MAX_SKINNED_INSTANCES * loader.MAX_JOINTS * size_of(matrix[4, 4]f32)),
		.GRAPHICS_STORAGE_READ,
	)
	renderer.scene_color = texture_create_with_usage(
		gfx_ctx,
		u32(gfx_ctx.window_size.x),
		u32(gfx_ctx.window_size.y),
		sdl.GetGPUSwapchainTextureFormat(gfx_ctx.gpu, gfx_ctx.window),
		{.COLOR_TARGET, .SAMPLER},
	)
	renderer.scene_depth_format = pick_depth_stencil_format(gfx_ctx.gpu)
	renderer.scene_depth = texture_create_with_usage(
		gfx_ctx,
		u32(gfx_ctx.window_size.x),
		u32(gfx_ctx.window_size.y),
		renderer.scene_depth_format,
		{.DEPTH_STENCIL_TARGET},
	)
	color_format := sdl.GetGPUSwapchainTextureFormat(gfx_ctx.gpu, gfx_ctx.window)
	renderer.msaa_supported =
		sdl.GPUTextureSupportsSampleCount(gfx_ctx.gpu, color_format, MSAA_SAMPLES) &&
		sdl.GPUTextureSupportsSampleCount(gfx_ctx.gpu, renderer.scene_depth_format, MSAA_SAMPLES)
	post_usage := sdl.GPUTextureUsageFlags{.COMPUTE_STORAGE_WRITE, .SAMPLER, .COLOR_TARGET}
	for format in ([?]sdl.GPUTextureFormat{.R16G16B16A16_FLOAT, .R8G8B8A8_UNORM}) {
		if sdl.GPUTextureSupportsFormat(gfx_ctx.gpu, format, .D2, post_usage) {
			renderer.post_format = format
			break
		}
	}
	assert(renderer.post_format != .INVALID, "no texture format supports compute write + sampler + color target")
	renderer.post_sampler = sampler_create(gfx_ctx, SAMPLER_LINEAR_CLAMP)
	renderer.shadow_enabled = true
	renderer.light_direction = linalg.normalize(DEFAULT_LIGHT_DIRECTION)
	renderer.shadow_map = texture_create_with_usage(
		gfx_ctx,
		SHADOW_MAP_SIZE,
		SHADOW_MAP_SIZE,
		.D32_FLOAT,
		{.DEPTH_STENCIL_TARGET, .SAMPLER},
	)
	// SDL3 GPU has no runtime query for comparison samplers; they are core in every backend.
	renderer.shadow_sampler = sampler_create(
		gfx_ctx,
		sdl.GPUSamplerCreateInfo {
			min_filter = .LINEAR, // bilinear comparison = hardware 2x2 PCF
			mag_filter = .LINEAR,
			address_mode_u = .CLAMP_TO_EDGE,
			address_mode_v = .CLAMP_TO_EDGE,
			address_mode_w = .CLAMP_TO_EDGE,
			compare_op = .LESS_OR_EQUAL,
			enable_compare = true,
		},
	)
	renderer.shadow_pipeline = create_shadow_pipeline(gfx_ctx)
	renderer.shadow_instanced_pipeline = create_shadow_instanced_pipeline(gfx_ctx)
	renderer_update_light(&renderer, renderer.light_direction)
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

	gfx_ctx := renderer.gfx_ctx
	gfx_ctx.scope_paused += 1 // renderer owns these targets, not the scene scope
	defer gfx_ctx.scope_paused -= 1
	_ = sdl.WaitForGPUIdle(gfx_ctx.gpu)
	size := texture_get(gfx_ctx, renderer.scene_color)
	width, height := size.width, size.height
	texture_destroy(gfx_ctx, renderer.scene_depth)
	texture_destroy(gfx_ctx, renderer.scene_color_msaa)
	renderer.scene_color_msaa = {}

	samples := MSAA_SAMPLES if enabled else sdl.GPUSampleCount._1
	renderer.scene_depth = texture_create_with_usage(
		gfx_ctx,
		width,
		height,
		renderer.scene_depth_format,
		{.DEPTH_STENCIL_TARGET},
		samples,
	)
	if enabled {
		renderer.scene_color_msaa = texture_create_with_usage(
			gfx_ctx,
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
	readback_destroy(renderer)
	buffer_destroy(renderer.gfx_ctx, renderer.instance_buffer)
	buffer_destroy(renderer.gfx_ctx, renderer.indirect_buffer)
	buffer_destroy(renderer.gfx_ctx, renderer.skinned_buffer)
	buffer_destroy(renderer.gfx_ctx, renderer.palette_buffer)
	delete(renderer.instance_transforms)
	delete(renderer.instance_offsets)
	delete(renderer.instance_previous)
	delete(renderer.indirect_commands)
	delete(renderer.indirect_previous)
	delete(renderer.skinned_transforms)
	delete(renderer.palettes)
	texture_destroy(renderer.gfx_ctx, renderer.scene_color)
	texture_destroy(renderer.gfx_ctx, renderer.scene_depth)
	texture_destroy(renderer.gfx_ctx, renderer.scene_color_msaa)
	texture_destroy(renderer.gfx_ctx, renderer.shadow_map)
	sampler_destroy(renderer.gfx_ctx, renderer.shadow_sampler)
	pipeline_destroy(renderer.gfx_ctx, renderer.shadow_pipeline)
	pipeline_destroy(renderer.gfx_ctx, renderer.shadow_instanced_pipeline)
	delete(renderer.pool.entries)
	for slot in Pass_Slot do delete(renderer.passes[slot])
	uploader_destroy(&renderer.uploader)
	delete(renderer.draw_items)
	delete(renderer.scene_hooks)
	renderer^ = {}
}

// Resizes the scene color, depth and MSAA color targets together (they must match).
// Waits for GPU idle; call between frames.
renderer_resize_targets :: proc(renderer: ^Renderer, width, height: u32) {
	renderer.gfx_ctx.scope_paused += 1 // renderer owns these targets, not the scene scope
	defer renderer.gfx_ctx.scope_paused -= 1
	texture_resize(renderer.gfx_ctx, &renderer.scene_color, width, height)
	texture_resize(renderer.gfx_ctx, &renderer.scene_depth, width, height)
	if renderer.msaa_enabled {
		texture_resize(renderer.gfx_ctx, &renderer.scene_color_msaa, width, height)
	}
}

renderer_load :: proc(renderer: ^Renderer, desc: Renderer_Load_Desc) -> Model {
	assert(len(desc.model_path) > 0)
	imported, ok := loader.model_import_from_gltf(desc.model_path)
	assert(ok, "renderer_load: model import failed")
	defer loader.model_import_destroy(&imported)
	return renderer_load_imported(renderer, &imported, desc.pipeline)
}

// GPU side of renderer_load for a model already decoded (possibly on a job thread). Does not free `imported`.
renderer_load_imported :: proc(renderer: ^Renderer, imported: ^loader.ImportedModel, pipeline: Pipeline_Handle) -> Model {
	assert(Resource_Handle(pipeline).generation != 0)
	model := model_create(renderer.gfx_ctx, imported, pipeline)
	model_upload_to_gpu(&model, &renderer.uploader)
	return model
}

renderer_unload :: proc(renderer: ^Renderer, model: ^Model) {
	model_destroy(renderer.gfx_ctx, model)
}

renderer_begin_frame :: proc(renderer: ^Renderer) {
	uploader_collect(&renderer.uploader) // frees staging of uploads the GPU has finished
	_ = begin_frame(renderer.gfx_ctx)
}

renderer_end_frame :: proc(renderer: ^Renderer) {
	assert(renderer.pass == nil)
	end_frame(renderer.gfx_ctx)
}

// Left/right/bottom/top planes (xyz = inward unit normal, w = offset) from a
// view-projection matrix (Gribb-Hartmann). Near/far are skipped: reverse-Z,
// infinite far, and a near-plane miss costs nothing.
frustum_planes :: proc(vp: matrix[4, 4]f32) -> (planes: [4][4]f32) {
	row :: proc(m: matrix[4, 4]f32, r: int) -> [4]f32 {
		return {m[r, 0], m[r, 1], m[r, 2], m[r, 3]}
	}
	r0, r1, r3 := row(vp, 0), row(vp, 1), row(vp, 3)
	planes = {r3 + r0, r3 - r0, r3 + r1, r3 - r1}
	for &plane in planes do plane /= linalg.length(plane.xyz)
	return
}

// World-space bounding sphere of a mesh instance. Radius 0 = bounds unknown.
renderable_sphere :: proc(mesh: ^Mesh, transform: matrix[4, 4]f32) -> (center: Vec3, radius: f32) {
	center = (transform * [4]f32{mesh.center.x, mesh.center.y, mesh.center.z, 1}).xyz
	scale := max(
		linalg.length(Vec3{transform[0, 0], transform[1, 0], transform[2, 0]}),
		linalg.length(Vec3{transform[0, 1], transform[1, 1], transform[2, 1]}),
		linalg.length(Vec3{transform[0, 2], transform[1, 2], transform[2, 2]}),
	)
	radius = mesh.radius * scale
	return
}

// True when the mesh's world-space bounding sphere is fully outside a side plane.
renderable_culled :: proc(
	planes: ^[4][4]f32,
	mesh: ^Mesh,
	transform: matrix[4, 4]f32,
) -> bool {
	if mesh.radius <= 0 do return false
	center, radius := renderable_sphere(mesh, transform)
	for plane in planes {
		if linalg.dot(plane.xyz, center) + plane.w < -radius do return true
	}
	return false
}

// True when the mesh's world-space bounding sphere lies entirely beyond `distance` from `eye`.
renderable_beyond :: proc(eye: Vec3, mesh: ^Mesh, transform: matrix[4, 4]f32, distance: f32) -> bool {
	if mesh.radius <= 0 do return false
	center, radius := renderable_sphere(mesh, transform)
	return linalg.distance(eye, center) - radius > distance
}

Extract_View :: struct {
	planes:        [4][4]f32,
	light_planes:  [4][4]f32, // sun box side planes; casters outside the camera frustum but inside these still cast
	view_distance: f32,
	shadows:       bool,
}

renderer_begin_extract :: proc(renderer: ^Renderer) -> Extract_View {
	view := Extract_View {
		planes        = frustum_planes(camera_view_projection(&renderer.camera)),
		// fog.a doubles as view distance (<= 0 = off): geometry past it is fully fogged, so skipping it is invisible.
		view_distance = renderer.fog.a,
		shadows       = renderer.shadow_enabled,
	}
	if renderer.shadow_enabled {
		// The light box is centred on the camera, which is final at extract.
		renderer_update_light(renderer, renderer.light_direction)
		view.light_planes = frustum_planes(renderer.light_view_projection)
	}
	return view
}

// Hooks run in registration order; user is borrowed.
renderer_add_scene_hook :: proc(renderer: ^Renderer, hook: Scene_Hook) {
	append(&renderer.scene_hooks, hook)
}

// Removes every hook registered with this user pointer, keeping the order of the rest.
renderer_remove_scene_hook :: proc(renderer: ^Renderer, user: rawptr) {
	for i := len(renderer.scene_hooks) - 1; i >= 0; i -= 1 {
		if renderer.scene_hooks[i].user == user do ordered_remove(&renderer.scene_hooks, i)
	}
}

// Conventional-Z orthographic (NDC depth in [0, 1], view looks down -z). The
// main pass is reverse-Z, so the shadow map must not reuse camera_perspective.
shadow_ortho :: proc(l, r, b, t, n, f: f32) -> (m: matrix[4, 4]f32) {
	m[0, 0] = 2 / (r - l)
	m[0, 3] = -(r + l) / (r - l)
	m[1, 1] = 2 / (t - b)
	m[1, 3] = -(t + b) / (t - b)
	m[2, 2] = -1 / (f - n)
	m[2, 3] = -n / (f - n)
	m[3, 3] = 1
	return
}

// Rebuilds light_view_projection for the sun direction (unit, toward the light),
// centered on the camera. The box center snaps to shadow texels in light space
// so the shadows do not shimmer while the camera moves.
renderer_update_light :: proc(renderer: ^Renderer, direction: [3]f32) {
	dir := linalg.normalize(direction)
	renderer.light_direction = dir
	forward := -dir
	world_up := Vec3{0, 1, 0}
	if abs(dir.y) > 0.99 do world_up = {0, 0, 1}
	right := linalg.normalize(linalg.cross(forward, world_up))
	up := linalg.cross(right, forward)
	center := renderer.camera.position
	texel := SHADOW_EXTENT / f32(SHADOW_MAP_SIZE)
	snap_x := math.round(linalg.dot(center, right) / texel) * texel - linalg.dot(center, right)
	snap_y := math.round(linalg.dot(center, up) / texel) * texel - linalg.dot(center, up)
	eye := center + right * snap_x + up * snap_y - forward * (SHADOW_DEPTH / 2)
	view := linalg.matrix4_look_at_f32(eye, eye + forward, world_up)
	half := f32(SHADOW_EXTENT / 2)
	renderer.light_view_projection = shadow_ortho(-half, half, -half, half, 0, SHADOW_DEPTH) * view
}

// Depth-only pass from the sun into shadow_map, before the scene pass. Only
// opaque WORLD items cast shadows; skinned items are skipped (no skinned depth pipeline yet).
renderer_draw_shadow :: proc(renderer: ^Renderer) {
	assert(renderer.pass == nil)
	gfx_ctx := renderer.gfx_ctx
	rt := Render_Target{depth = texture_get(gfx_ctx, renderer.shadow_map).handle, clear_depth = f32(1)} // conventional Z: 1 is far
	renderer.pass = begin_pass(renderer, rt)
	assert(renderer.pass != nil)
	renderer.view_projection = renderer.light_view_projection
	renderer.pass_msaa = false
	renderer.bound_pipeline = {}
	renderer.bound_material = nil
	if len(renderer.instance_transforms) > 0 do renderer_bind_static_instances(renderer)

	bound_shadow: Pipeline_Handle
	index := 0
	for index < len(renderer.draw_items) {
		item := &renderer.draw_items[index]
		material_pipeline := pipeline_get(gfx_ctx, item.material.pipeline)
		if item.layer != .WORLD || material_pipeline.skinned {
			index += 1
			continue
		}
		shadow := renderer.shadow_instanced_pipeline if material_pipeline.instanced else renderer.shadow_pipeline
		if bound_shadow != shadow {
			sdl.BindGPUGraphicsPipeline(renderer.pass, pipeline_native(pipeline_get(gfx_ctx, shadow), false))
			bound_shadow = shadow
		}
		if !material_pipeline.instanced {
			pipeline_bind_draw(gfx_ctx, shadow, gfx_ctx.command_buffer, {view_projection = renderer.light_view_projection, model_transform = item.transform})
			mesh_draw(gfx_ctx, item.mesh, renderer.pass)
			index += 1
			continue
		}
		run_end := index + 1
		for run_end < len(renderer.draw_items) {
			other := &renderer.draw_items[run_end]
			if other.layer != .WORLD || other.mesh != item.mesh || other.material != item.material do break
			run_end += 1
		}
		pipeline_bind_draw(gfx_ctx, shadow, gfx_ctx.command_buffer, {view_projection = renderer.light_view_projection, first_instance = renderer.instance_offsets[index]})
		mesh_draw_instanced(gfx_ctx, item.mesh, renderer.pass, u32(run_end - index), 0)
		index = run_end
	}
	renderer_end_pass(renderer)
}

renderer_draw_submitted :: proc(renderer: ^Renderer) {
	// Before hooks sit outside prepare/flush timing and before the pass opens.
	for hook in renderer.scene_hooks {
		if hook.before != nil do hook.before(renderer, hook.user)
	}
	start := time.tick_now()
	renderer_prepare(renderer)
	renderer.prepare_time = time.tick_since(start)
	if renderer.shadow_enabled {
		shadow_start := time.tick_now()
		renderer_draw_shadow(renderer)
		renderer.shadow_time = time.tick_since(shadow_start)
	} else do renderer.shadow_time = 0
	renderer_begin_pass(renderer, camera_view_projection(&renderer.camera))
	start = time.tick_now()
	renderer_flush(renderer)
	renderer.flush_time = time.tick_since(start)
	for hook in renderer.scene_hooks {
		if hook.draw == nil do continue
		hook.draw(renderer, hook.user)
		// Hook may bind its own pipelines; drop the cache so the next draw rebinds.
		renderer.bound_pipeline = {}
		renderer.bound_material = nil
	}
	renderer_end_pass(renderer)
}

Extract_Proc :: #type proc(renderer: ^Renderer, user: rawptr)

// Whole frame: extract, draw, post-process, present. Draws nothing when the
// swapchain is unavailable (minimized window).
renderer_render_frame :: proc(renderer: ^Renderer, extract: Extract_Proc, user: rawptr) {
	renderer_begin_frame(renderer)
	if renderer.gfx_ctx.swapchain != nil {
		extract_start := time.tick_now()
		extract(renderer, user)
		renderer.extract_time = time.tick_since(extract_start)
		renderer_draw_submitted(renderer)
		final := renderer_run_post(renderer)
		renderer_present(renderer, final)
	}
	renderer_end_frame(renderer)
	readback_finish(renderer)
	free_all(context.temp_allocator)
}

// Sorts the frame's draw items, gathers per-instance transforms for
// instanced pipelines, and uploads them — all before the pass opens, since
// the upload submits its own command buffer.
renderer_prepare :: proc(renderer: ^Renderer) {
	renderer_sort_draw_items(renderer.draw_items[:])
	clear(&renderer.instance_transforms)
	clear(&renderer.instance_offsets)
	clear(&renderer.skinned_transforms)
	clear(&renderer.palettes)
	renderer.draw_calls = 0
	renderer.triangles = 0
	renderer.instanced_draws, renderer.instance_count = 0, 0
	renderer.pipeline_binds, renderer.material_binds = 0, 0
	i := 0
	for i < len(renderer.draw_items) {
		item := renderer.draw_items[i]
		pipeline := pipeline_get(renderer.gfx_ctx, item.material.pipeline)
		if pipeline.skinned && item.shadow_only {
			append(&renderer.instance_offsets, 0) // no skinned shadow pipeline: keep offsets aligned, upload nothing
			i += 1
			continue
		}
		if pipeline.skinned {
			assert(item.pose != nil, "skinned draw item without pose")
			if len(renderer.skinned_transforms) >= MAX_SKINNED_INSTANCES {
				// Dropped before runs/offsets are built so both stay aligned with the uploaded buffers.
				if !renderer.skinned_overflow_logged {
					log.errorf("too many skinned instances (max %d)", MAX_SKINNED_INSTANCES)
					renderer.skinned_overflow_logged = true
				}
				ordered_remove(&renderer.draw_items, i)
				continue
			}
			append(&renderer.instance_offsets, u32(len(renderer.skinned_transforms)))
			append(&renderer.skinned_transforms, item.transform)
			append(&renderer.palettes, ..item.pose.palette[:])
		} else if pipeline.instanced {
			append(&renderer.instance_offsets, u32(len(renderer.instance_transforms)))
			append(&renderer.instance_transforms, item.transform)
		} else {
			append(&renderer.instance_offsets, 0)
		}
		i += 1
	}
	renderer_upload_skinned_instances(renderer)
	if len(renderer.instance_transforms) == 0 do return
	renderer_upload_indirect(renderer) // before the static-scene early return: grouping can change with identical transforms
	current := slice.to_bytes(renderer.instance_transforms[:])
	if len(renderer.instance_transforms) == len(renderer.instance_previous) &&
	   mem.compare(current, slice.to_bytes(renderer.instance_previous[:])) == 0 {
		return // static scene: the buffer on the GPU is already correct
	}
	clear(&renderer.instance_previous)
	append(&renderer.instance_previous, ..renderer.instance_transforms[:])
	renderer.instance_buffer = buffer_stage(
		renderer.gfx_ctx,
		renderer.instance_buffer,
		renderer.instance_transforms[:],
		.GRAPHICS_STORAGE_READ,
	)
	uploader_begin(&renderer.uploader)
	uploader_upload_buffer(&renderer.uploader, renderer.instance_buffer)
	uploader_flush(&renderer.uploader)
	buffer_get(renderer.gfx_ctx, renderer.instance_buffer)._temporary_raw_data = nil
}
// Builds one indirect command per non-skinned instanced run (same grouping as renderer_flush) and uploads on change.
renderer_upload_indirect :: proc(renderer: ^Renderer) {
	if !indirect_draws do return
	clear(&renderer.indirect_commands)
	index := 0
	for index < len(renderer.draw_items) {
		item := &renderer.draw_items[index]
		pipeline := pipeline_get(renderer.gfx_ctx, item.material.pipeline)
		if item.shadow_only || !pipeline.instanced {
			index += 1
			continue
		}
		run_end := index + 1
		for run_end < len(renderer.draw_items) {
			other := &renderer.draw_items[run_end]
			if other.mesh != item.mesh || other.material != item.material || other.shadow_only do break
			run_end += 1
		}
		if !pipeline.skinned {
			append(&renderer.indirect_commands, sdl.GPUIndexedIndirectDrawCommand{num_indices = item.mesh.num_indices, num_instances = u32(run_end - index)})
		}
		index = run_end
	}
	if len(renderer.indirect_commands) == 0 || slice.equal(renderer.indirect_commands[:], renderer.indirect_previous[:]) do return
	clear(&renderer.indirect_previous)
	append(&renderer.indirect_previous, ..renderer.indirect_commands[:])
	renderer.indirect_buffer = buffer_stage(renderer.gfx_ctx, renderer.indirect_buffer, renderer.indirect_commands[:], .INDIRECT)
	uploader_begin(&renderer.uploader)
	uploader_upload_buffer(&renderer.uploader, renderer.indirect_buffer)
	uploader_flush(&renderer.uploader)
	buffer_get(renderer.gfx_ctx, renderer.indirect_buffer)._temporary_raw_data = nil
}

renderer_upload_skinned_instances :: proc(renderer: ^Renderer) {
	if len(renderer.skinned_transforms) == 0 do return
	renderer.skinned_buffer = buffer_stage(
		renderer.gfx_ctx,
		renderer.skinned_buffer,
		renderer.skinned_transforms[:],
		.GRAPHICS_STORAGE_READ,
	)
	renderer.palette_buffer = buffer_stage(
		renderer.gfx_ctx,
		renderer.palette_buffer,
		renderer.palettes[:],
		.GRAPHICS_STORAGE_READ,
	)
	uploader_begin(&renderer.uploader)
	uploader_upload_buffer(&renderer.uploader, renderer.skinned_buffer)
	uploader_upload_buffer(&renderer.uploader, renderer.palette_buffer)
	uploader_flush(&renderer.uploader)
	buffer_get(renderer.gfx_ctx, renderer.skinned_buffer)._temporary_raw_data = nil
	buffer_get(renderer.gfx_ctx, renderer.palette_buffer)._temporary_raw_data = nil
}

renderer_bind_static_instances :: proc(renderer: ^Renderer) {
	instance_buffer := buffer_get(renderer.gfx_ctx, renderer.instance_buffer)
	sdl.BindGPUVertexStorageBuffers(renderer.pass, 0, &(instance_buffer.handle), 1)
}

// Attachments of one pass. A nil texture means the attachment is absent; a nil
// clear value means load the existing contents.
Render_Target :: struct {
	color:         ^sdl.GPUTexture,   // nil for depth-only passes
	color_msaa:    ^sdl.GPUTexture,   // when set: draw here, resolve into color at pass end
	clear_color:   Maybe(sdl.FColor),
	depth:         ^sdl.GPUTexture,   // nil for color-only passes
	clear_depth:   Maybe(f32),
	depth_store:   sdl.GPUStoreOp,    // zero value STORE
	clear_stencil: bool,              // clear stencil to 0 and store it
}

// Opens a pass on the frame command buffer with the attachments of rt. The
// caller assigns renderer.pass and sets the view-projection state.
begin_pass :: proc(renderer: ^Renderer, rt: Render_Target) -> ^sdl.GPURenderPass {
	assert(renderer.pass == nil)
	assert(renderer.gfx_ctx.command_buffer != nil)
	assert(rt.color != nil || rt.depth != nil)

	color_target := sdl.GPUColorTargetInfo{texture = rt.color, load_op = .LOAD, store_op = .STORE}
	if clear, ok := rt.clear_color.?; ok {
		color_target.load_op = .CLEAR
		color_target.clear_color = clear
	}
	if rt.color_msaa != nil {
		color_target.resolve_texture = rt.color
		color_target.texture = rt.color_msaa
		color_target.store_op = .RESOLVE
	}
	depth_target := sdl.GPUDepthStencilTargetInfo{texture = rt.depth, load_op = .LOAD, store_op = rt.depth_store}
	if clear, ok := rt.clear_depth.?; ok {
		depth_target.load_op = .CLEAR
		depth_target.clear_depth = clear
	}
	if rt.clear_stencil {
		depth_target.stencil_load_op = .CLEAR
		depth_target.stencil_store_op = .STORE
	}

	color_ptr: ^sdl.GPUColorTargetInfo
	color_count: u32
	if rt.color != nil {
		color_ptr = &color_target
		color_count = 1
	}
	depth_ptr: ^sdl.GPUDepthStencilTargetInfo
	if rt.depth != nil do depth_ptr = &depth_target
	pass := sdl.BeginGPURenderPass(renderer.gfx_ctx.command_buffer, color_ptr, color_count, depth_ptr)
	assert(pass != nil)
	return pass
}

renderer_begin_pass :: proc(renderer: ^Renderer, view_projection: matrix[4, 4]f32) {
	assert(renderer.pass == nil)
	assert(renderer.gfx_ctx.command_buffer != nil)
	assert(renderer.gfx_ctx.swapchain != nil)

	rt := Render_Target {
		color         = texture_get(renderer.gfx_ctx, renderer.scene_color).handle,
		clear_color   = sdl.FColor(color_srgb_to_linear(renderer.clear_color)),
		depth         = texture_get(renderer.gfx_ctx, renderer.scene_depth).handle,
		clear_depth   = f32(0), // reverse-Z: 0 is the far plane
		depth_store   = .DONT_CARE,
		clear_stencil = true,
	}
	if renderer.msaa_enabled {
		// Draw into the multisampled texture; at pass end the samples are
		// averaged into scene_color and the multisampled data is dropped.
		rt.color_msaa = texture_get(renderer.gfx_ctx, renderer.scene_color_msaa).handle
	}
	renderer.pass = begin_pass(renderer, rt)
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
// attachment and idactor view-projection. For UI drawn on top of the
// finished frame (pair with depth-less, blended pipelines). Close with
// renderer_end_pass.
renderer_begin_overlay_pass :: proc(renderer: ^Renderer, target: Texture_Handle) {
	assert(renderer.pass == nil)
	assert(renderer.gfx_ctx.command_buffer != nil)
	renderer.pass = begin_pass(renderer, Render_Target{color = texture_get(renderer.gfx_ctx, target).handle})
	assert(renderer.pass != nil)
	renderer.view_projection = linalg.MATRIX4F32_IDENTITY
	renderer.bound_pipeline = {}
	renderer.bound_material = nil
}

// Present pass: a CLEAR pass directly on the swapchain with idactor
// view-projection, for compositing the final frame (editor chrome +
// viewport) without a blit. Close with renderer_end_pass.
renderer_begin_present_pass :: proc(renderer: ^Renderer) {
	assert(renderer.pass == nil)
	assert(renderer.gfx_ctx.command_buffer != nil)
	assert(renderer.gfx_ctx.swapchain != nil)
	renderer.pass = begin_pass(renderer, Render_Target{color = renderer.gfx_ctx.swapchain, clear_color = sdl.FColor(color_srgb_to_linear({0.08, 0.08, 0.1, 1}))})
	assert(renderer.pass != nil)
	renderer.view_projection = linalg.MATRIX4F32_IDENTITY
	renderer.bound_pipeline = {}
	renderer.bound_material = nil
}

// Blits a texture (usually the scene color or a post-processing result) onto
// the swapchain. Must run outside any pass, on the frame command buffer.
renderer_present :: proc(renderer: ^Renderer, source: Texture_Handle) {
	assert(renderer.pass == nil)
	gfx_ctx := renderer.gfx_ctx
	assert(gfx_ctx.frame_open && gfx_ctx.command_buffer != nil)
	if gfx_ctx.swapchain == nil do return
	texture := texture_get(gfx_ctx, source)
	sdl.BlitGPUTexture(
		gfx_ctx.command_buffer,
		{
			source = {texture = texture.handle, w = texture.width, h = texture.height},
			destination = {
				texture = gfx_ctx.swapchain,
				w = u32(gfx_ctx.window_size.x),
				h = u32(gfx_ctx.window_size.y),
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
	pipeline := pipeline_get(renderer.gfx_ctx, material.pipeline)

	if renderer.bound_pipeline != material.pipeline {
		pipeline_bind_native(renderer.pass, pipeline, renderer.pass_msaa)
		renderer.bound_pipeline = material.pipeline
		renderer.pipeline_binds += 1
		renderer.bound_material = nil
	}
	if renderer.bound_material != material {
		pipeline_bind_material(
			renderer.gfx_ctx,
			renderer.pass,
			renderer.gfx_ctx.command_buffer,
			material,
		)
		renderer.bound_material = material
		renderer.material_binds += 1
	}

	pipeline_bind_draw(
		renderer.gfx_ctx,
		material.pipeline,
		renderer.gfx_ctx.command_buffer,
		{
			view_projection = renderer.view_projection,
			camera_position = renderer.camera.position,
			light_view_projection = renderer.light_view_projection,
			shadow_enabled = renderer.shadow_enabled,
			fog = renderer.fog,
			model_transform = item.transform,
			material = material,
		},
	)
	if pipeline_get(renderer.gfx_ctx, material.pipeline).pulled {
		mesh_draw_pulled(renderer.gfx_ctx, mesh, renderer.pass)
	} else {
		mesh_draw(renderer.gfx_ctx, mesh, renderer.pass)
	}
	renderer.draw_calls += 1
	renderer.triangles += triangle_count(mesh)
}

// One instanced draw for a run of items sharing mesh and material. The
// shader reads transforms from the instance storage buffer at
// SV_InstanceID = first_instance + i.
renderer_draw_instanced_run :: proc(
	renderer: ^Renderer,
	item: ^DrawItem,
	count: int,
	first_instance: u32,
	indirect_slot := -1,
) {
	assert(renderer.pass != nil)
	mesh := item.mesh
	material := item.material
	pipeline := pipeline_get(renderer.gfx_ctx, material.pipeline)

	if renderer.bound_pipeline != material.pipeline {
		pipeline_bind_native(renderer.pass, pipeline, renderer.pass_msaa)
		renderer.bound_pipeline = material.pipeline
		renderer.pipeline_binds += 1
		renderer.bound_material = nil
	}
	if renderer.bound_material != material {
		pipeline_bind_material(
			renderer.gfx_ctx,
			renderer.pass,
			renderer.gfx_ctx.command_buffer,
			material,
		)
		renderer.bound_material = material
		renderer.material_binds += 1
	}
	pipeline_bind_draw(
		renderer.gfx_ctx,
		material.pipeline,
		renderer.gfx_ctx.command_buffer,
		{
			view_projection = renderer.view_projection,
			camera_position = renderer.camera.position,
			light_view_projection = renderer.light_view_projection,
			shadow_enabled = renderer.shadow_enabled,
			fog = renderer.fog,
			model_transform = {},
			material = material,
			first_instance = first_instance,
		},
	)
	if indirect_slot >= 0 && mesh.num_indices > 0 {
		mesh_draw_indirect(renderer.gfx_ctx, mesh, renderer.pass, buffer_get(renderer.gfx_ctx, renderer.indirect_buffer).handle, u32(indirect_slot * size_of(sdl.GPUIndexedIndirectDrawCommand)))
	} else {
		mesh_draw_instanced(renderer.gfx_ctx, mesh, renderer.pass, u32(count), 0)
	}
	renderer.draw_calls += 1
	renderer.instanced_draws += 1
	renderer.instance_count += count
	renderer.triangles += count * triangle_count(mesh)
}

triangle_count :: proc(mesh: ^Mesh) -> int {
	n := mesh.num_indices
	if n == 0 do n = mesh.num_vertices
	return int(n) / 3
}

// Low-level submission: call any number of times before render, outside a pass.
renderer_submit :: proc(
	renderer: ^Renderer,
	mesh: ^Mesh,
	material: ^Material,
	transform: matrix[4, 4]f32,
	layer: Render_Layer = .WORLD,
	pose: ^Pose = nil,
	shadow_only := false,
) {
	assert(renderer.pass == nil)
	assert(mesh != nil && material != nil)
	append_elem(
		&renderer.draw_items,
		DrawItem{mesh = mesh, material = material, transform = transform, layer = layer, pose = pose, shadow_only = shadow_only},
	)
}

pipeline_handle_key :: proc(handle: Pipeline_Handle) -> u64 {
	raw := Resource_Handle(handle)
	return u64(raw.generation) << 32 | u64(raw.index)
}

// Sorting works on 16-byte (key, index) entries instead of moving whole
// DrawItems in the comparator. Material and mesh pointers map to small dense
// indices so the order fits one u64: layer | pipeline | material | mesh.
Sort_Entry :: struct {
	key:   u64,
	index: u32,
}

renderer_sort_draw_items :: proc(items: []DrawItem) {
	count := len(items)
	if count < 2 do return

	unique_materials := make([dynamic]^Material, 0, 16, context.temp_allocator)
	unique_meshes := make([dynamic]^Mesh, 0, 16, context.temp_allocator)
	entries := make([]Sort_Entry, count, context.temp_allocator)
	for item, index in items {
		material_index := dense_index(&unique_materials, item.material)
		mesh_index := dense_index(&unique_meshes, item.mesh)
		pipeline := u64(Resource_Handle(item.material.pipeline).index)
		assert(material_index < 1 << 20 && mesh_index < 1 << 19 && pipeline < 1 << 16)
		entries[index] = {
			// layer | pipeline | material | mesh | shadow_only: shadow-only items trail their own run.
			key   = u64(item.layer) << 57 | pipeline << 41 | u64(material_index) << 21 | u64(mesh_index) << 1 | u64(item.shadow_only ? 1 : 0),
			index = u32(index),
		}
	}
	renderer_radix_sort(entries)

	sorted := make([]DrawItem, count, context.temp_allocator)
	for entry, index in entries do sorted[index] = items[entry.index]
	copy(items, sorted)
}

@(private = "file")
dense_index :: proc(seen: ^[dynamic]$T, value: T) -> int {
	for v, i in seen {
		if v == value do return i
	}
	append(seen, value)
	return len(seen) - 1
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
		renderer_bind_static_instances(renderer)
	}
	renderer.indirect_cursor = 0
	index := 0
	skinned_bound := false
	for index < len(renderer.draw_items) {
		item := &renderer.draw_items[index]
		if item.shadow_only {
			index += 1
			continue
		}
		pipeline := pipeline_get(renderer.gfx_ctx, item.material.pipeline)
		if !pipeline.instanced {
			renderer_draw_item(renderer, item)
			index += 1
			continue
		}
		if pipeline.skinned {
			pipeline.bind_skinned_storage(
				renderer.gfx_ctx,
				renderer.pass,
				renderer.skinned_buffer,
				renderer.palette_buffer,
			)
			skinned_bound = true
		} else if skinned_bound {
			renderer_bind_static_instances(renderer)
			skinned_bound = false
		}
		run_end := index + 1
		for run_end < len(renderer.draw_items) {
			other := &renderer.draw_items[run_end]
			if other.mesh != item.mesh || other.material != item.material || other.shadow_only do break
			run_end += 1
		}
		slot := -1
		if indirect_draws && !pipeline.skinned {
			slot = renderer.indirect_cursor
			renderer.indirect_cursor += 1
		}
		renderer_draw_instanced_run(
			renderer,
			item,
			run_end - index,
			renderer.instance_offsets[index],
			slot,
		)
		index = run_end
	}
	clear(&renderer.draw_items)
}
