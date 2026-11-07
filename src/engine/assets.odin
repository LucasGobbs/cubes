package engine

import "core:strings"
import gbbfx "../gbbfx"
import defaults "../gbbfx/defaults"
import loader "../gbbfx/loader"

Assets :: struct {
	models:           map[string]^Model_Asset,
	sampler:          gbbfx.Sampler_Handle,
	static_pipeline:  gbbfx.Pipeline_Handle,
	skinned_pipeline: gbbfx.Pipeline_Handle,
}

// Heap-allocated so Renderable pointers into the model stay valid as the cache grows.
Model_Asset :: struct {
	model:   gbbfx.Model,
	skinned: bool,
}

// Loads on first use and caches by path until world_destroy.
// shortcut: no eviction, every loaded model stays resident; add refcounts when a scene needs to unload models.
asset_model :: proc(world: ^World, path: string) -> ^Model_Asset {
	if asset, found := world.assets.models[path]; found do return asset

	gfx := world.gfx
	assets := &world.assets
	asset := new(Model_Asset)
	asset.skinned = loader.gltf_has_skin(path)
	if !is_set(assets.sampler) {
		assets.sampler = gbbfx.gfx_sampler_create(gfx, gbbfx.SAMPLER_TRILINEAR)
	}

	if asset.skinned {
		if !is_set(assets.skinned_pipeline) {
			assets.skinned_pipeline = defaults.create_textured_skinned_pipeline(gfx)
		}
		imported, ok := loader.model_import_skinned_from_gltf(path)
		assert(ok, "engine: model load failed")
		defer loader.skinned_model_destroy(&imported)
		asset.model = gbbfx.skinned_model_create(gfx, &imported, assets.skinned_pipeline)
		gbbfx.model_upload_to_gpu(&asset.model, &gfx.renderer.uploader)
		defaults.bind_textured_skinned_material(&asset.model.material, gbbfx.model_texture(&asset.model), assets.sampler)
	} else {
		if !is_set(assets.static_pipeline) {
			assets.static_pipeline = defaults.create_textured_instanced_pipeline(gfx)
		}
		asset.model = gbbfx.gfx_load(gfx, {model_path = path, pipeline = assets.static_pipeline})
		defaults.bind_textured_instanced_material(&asset.model.material, gbbfx.model_texture(&asset.model), assets.sampler)
	}

	world.assets.models[strings.clone(path)] = asset
	return asset
}

assets_destroy :: proc(world: ^World) {
	assets := &world.assets
	for path, asset in assets.models {
		gbbfx.gfx_unload(world.gfx, &asset.model)
		free(asset)
		delete(path)
	}
	delete(assets.models)
	if is_set(assets.sampler) do gbbfx.gfx_sampler_destroy(world.gfx, assets.sampler)
	if is_set(assets.static_pipeline) do gbbfx.gfx_pipeline_destroy(world.gfx, assets.static_pipeline)
	if is_set(assets.skinned_pipeline) do gbbfx.gfx_pipeline_destroy(world.gfx, assets.skinned_pipeline)
	assets^ = {}
}

// Generation 0 marks a handle that was never created (the zero value).
@(private = "file")
is_set :: proc(handle: $H) -> bool {
	return gbbfx.Resource_Handle(handle).generation != 0
}
