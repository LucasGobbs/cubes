package engine

import "core:strings"
import gfx "gfx"
import loader "gfx/loader"

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
		imported, ok := loader.model_import_skinned_from_gltf(path)
		assert(ok, "engine: model load failed")
		defer loader.skinned_model_destroy(&imported)
		asset.model = gfx.model_create_skinned(gfx_ctx, &imported, assets.skinned_pipeline)
		gfx.model_upload_to_gpu(&asset.model, &gfx_ctx.renderer.uploader)
		gfx.bind_textured_skinned_material(&asset.model.material, gfx.model_texture(&asset.model), assets.sampler)
	} else {
		if !is_set(assets.static_pipeline) {
			assets.static_pipeline = gfx.create_textured_instanced_pipeline(gfx_ctx)
		}
		asset.model = gfx.model_load(gfx_ctx, {model_path = path, pipeline = assets.static_pipeline})
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
	handle := gfx.texture_load(world.gfx_ctx, path)
	world.assets.textures[strings.clone(path)] = handle
	return handle
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
