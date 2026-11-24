package engine

import "base:intrinsics"
import "core:strings"
import "core:sync"
import gfx "gfx"
import loader "gfx/loader"
import "jobs"

Assets :: struct {
	models:           map[string]^Model_Asset,
	textures:         map[string]gfx.Texture_Handle,
	sampler:          gfx.Sampler_Handle,
	static_pipeline:  gfx.Pipeline_Handle,
	skinned_pipeline: gfx.Pipeline_Handle,
}

// Heap-allocated so Renderable pointers into the model stay valid as the cache grows.
Model_Asset :: struct {
	model:   gfx.Model,
	skinned: bool,
}

// Loads on first use and caches by path until world_destroy.
// shortcut: no eviction, every loaded model stays resident; add refcounts when a scene needs to unload models.
asset_model :: proc(world: ^World, path: string) -> ^Model_Asset {
	if asset, found := world.assets.models[path]; found do return asset

	gfx_ctx := world.gfx_ctx
	assets := &world.assets
	asset := new(Model_Asset)
	asset.skinned = loader.gltf_has_skin(path)
	if !is_set(assets.sampler) {
		assets.sampler = gfx.sampler_create(gfx_ctx, gfx.SAMPLER_TRILINEAR)
	}

	if asset.skinned {
		if !is_set(assets.skinned_pipeline) {
			assets.skinned_pipeline = gfx.create_textured_skinned_pipeline(gfx_ctx)
		}
		imported, ok := prefetch_take_skinned(path)
		if !ok do imported, ok = loader.model_import_skinned_from_gltf(path)
		assert(ok, "engine: model load failed")
		defer loader.skinned_model_destroy(&imported)
		asset.model = gfx.model_create_skinned(gfx_ctx, &imported, assets.skinned_pipeline)
		gfx.model_upload_to_gpu(&asset.model, &gfx_ctx.renderer.uploader)
		gfx.bind_textured_skinned_material(&asset.model.material, gfx.model_texture(&asset.model), assets.sampler)
	} else {
		if !is_set(assets.static_pipeline) {
			assets.static_pipeline = gfx.create_textured_instanced_pipeline(gfx_ctx)
		}
		if imported, ok := prefetch_take_static(path); ok {
			defer loader.model_import_destroy(&imported)
			asset.model = gfx.renderer_load_imported(&gfx_ctx.renderer, &imported, assets.static_pipeline)
		} else {
			asset.model = gfx.model_load(gfx_ctx, {model_path = path, pipeline = assets.static_pipeline})
		}
		gfx.bind_textured_instanced_material(&asset.model.material, gfx.model_texture(&asset.model), assets.sampler)
	}

	world.assets.models[strings.clone(path)] = asset
	return asset
}

// Loads everything a scene definition lists, so game code never calls a loader.
// Use asset_model / asset_texture afterwards; both are then pure cache hits.
assets_load :: proc(world: ^World, def: Assets_Def) {
	for path in def.models do asset_model(world, path)
	for path in def.textures do asset_texture(world, path)
}

// Loads on first use and caches by path until world_destroy.
asset_texture :: proc(world: ^World, path: string) -> gfx.Texture_Handle {
	if handle, found := world.assets.textures[path]; found do return handle
	if image, ok := prefetch_take_image(path); ok {
		defer loader.image_destroy(&image)
		handle := gfx.texture_create_from_image(world.gfx_ctx, &image)
		world.assets.textures[strings.clone(path)] = handle
		return handle
	}
	handle := gfx.texture_load(world.gfx_ctx, path)
	world.assets.textures[strings.clone(path)] = handle
	return handle
}

// CPU-side decodes made on job threads (Scene.load) and not yet turned into GPU resources.
// asset_model / asset_texture take an entry (and own it) instead of decoding again.
@(private = "file")
Prefetched :: struct {
	mutex:   sync.Mutex,
	static:  map[string]loader.ImportedModel,
	skinned: map[string]loader.ImportedSkinnedModel,
	images:  map[string]loader.ImageData,
}

@(private = "file")
prefetched: Prefetched

@(private = "file")
Prefetch_Job :: struct {
	lc:   ^Load_Context,
	path: string, // owned
}

// Queues a CPU decode of a .glb/.gltf (static or skinned) or an image on the load's job group.
// Call from Scene.load; progress is reported through lc.
asset_prefetch :: proc(lc: ^Load_Context, path: string) {
	job := new(Prefetch_Job)
	job.lc, job.path = lc, strings.clone(path)
	intrinsics.atomic_add(&lc.prefetch_total, 1)
	jobs.run(lc.jobs, &lc.group, prefetch_main, job)
}

// Everything a scene definition will ask asset_model / asset_texture for.
asset_prefetch_def :: proc(lc: ^Load_Context, def: ^Scene_Def) {
	seen := make(map[string]struct{}, context.temp_allocator)
	visit :: proc(lc: ^Load_Context, seen: ^map[string]struct{}, path: string) {
		if path == "" || path in seen do return
		seen[path] = {}
		asset_prefetch(lc, path)
	}
	for path in def.assets.models do visit(lc, &seen, path)
	for path in def.assets.textures do visit(lc, &seen, path)
	for actor in def.actors {
		visit(lc, &seen, actor.model)
		visit(lc, &seen, actor.sprite)
	}
}

// Frees the entries a dropped load decoded but nobody consumed.
asset_prefetch_discard_def :: proc(def: ^Scene_Def) {
	discard :: proc(path: string) {
		if model, ok := prefetch_take_static(path); ok do loader.model_import_destroy(&model)
		if model, ok := prefetch_take_skinned(path); ok do loader.skinned_model_destroy(&model)
		if image, ok := prefetch_take_image(path); ok do loader.image_destroy(&image)
	}
	for path in def.assets.models do discard(path)
	for path in def.assets.textures do discard(path)
	for actor in def.actors {
		discard(actor.model)
		discard(actor.sprite)
	}
}

@(private = "file")
prefetch_main :: proc(data: rawptr) {
	job := (^Prefetch_Job)(data)
	defer {
		delete(job.path)
		free(job)
	}
	path := job.path
	if strings.has_suffix(path, ".glb") || strings.has_suffix(path, ".gltf") {
		if loader.gltf_has_skin(path) {
			if model, ok := loader.model_import_skinned_from_gltf(path); ok do prefetch_store(&prefetched.skinned, path, model, loader.skinned_model_destroy)
		} else {
			if model, ok := loader.model_import_from_gltf(path); ok do prefetch_store(&prefetched.static, path, model, loader.model_import_destroy)
		}
	} else {
		prefetch_store(&prefetched.images, path, loader.image_load(path), loader.image_destroy)
	}
	done := intrinsics.atomic_add(&job.lc.prefetch_done, 1) + 1
	total := intrinsics.atomic_load(&job.lc.prefetch_total)
	load_progress(job.lc, 0.1 + 0.9 * f32(done) / f32(total))
}

// First decode of a path wins; a duplicate is freed.
@(private = "file")
prefetch_store :: proc(entries: ^map[string]$T, path: string, value: T, destroy: proc(_: ^T)) {
	value := value
	sync.mutex_lock(&prefetched.mutex)
	defer sync.mutex_unlock(&prefetched.mutex)
	if path in entries {
		destroy(&value)
		return
	}
	entries[strings.clone(path)] = value
}

@(private = "file")
prefetch_take :: proc(entries: ^map[string]$T, path: string) -> (value: T, ok: bool) {
	sync.mutex_lock(&prefetched.mutex)
	defer sync.mutex_unlock(&prefetched.mutex)
	key: string
	key, value = delete_key(entries, path)
	if key == "" do return {}, false
	delete(key)
	return value, true
}

@(private = "file")
prefetch_take_static :: proc(path: string) -> (loader.ImportedModel, bool) {
	return prefetch_take(&prefetched.static, path)
}

@(private = "file")
prefetch_take_skinned :: proc(path: string) -> (loader.ImportedSkinnedModel, bool) {
	return prefetch_take(&prefetched.skinned, path)
}

@(private = "file")
prefetch_take_image :: proc(path: string) -> (loader.ImageData, bool) {
	return prefetch_take(&prefetched.images, path)
}

assets_destroy :: proc(world: ^World) {
	for path, handle in world.assets.textures {
		gfx.texture_destroy(world.gfx_ctx, handle)
		delete(path)
	}
	delete(world.assets.textures)
	assets := &world.assets
	for path, asset in assets.models {
		gfx.model_unload(world.gfx_ctx, &asset.model)
		free(asset)
		delete(path)
	}
	delete(assets.models)
	if is_set(assets.sampler) do gfx.sampler_destroy(world.gfx_ctx, assets.sampler)
	if is_set(assets.static_pipeline) do gfx.pipeline_destroy(world.gfx_ctx, assets.static_pipeline)
	if is_set(assets.skinned_pipeline) do gfx.pipeline_destroy(world.gfx_ctx, assets.skinned_pipeline)
	assets^ = {}
}

// Generation 0 marks a handle that was never created (the zero value).
@(private = "file")
is_set :: proc(handle: $H) -> bool {
	return gfx.Resource_Handle(handle).generation != 0
}
