package default

import gfx "../gfx"

SKYBOX_PATH :: "static/skybox/skybox-day.png"

// Loads a .glb/.gltf and binds its base color texture to the default
// textured material.
load_textured_model :: proc(
	dev: ^gfx.Device,
	model_path: string,
	pipeline: gfx.Pipeline_Handle,
	sampler: gfx.Sampler_Handle,
) -> gfx.Model {
	model := gfx.model_load(dev, {model_path = model_path, pipeline = pipeline})
	bind_textured_material(&model.material, gfx.model_texture(&model), sampler)
	return model
}
