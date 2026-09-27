package main

import goose "goose"

Material_Texture_Binding :: struct {
	texture_parameter: goose.Texture_Binding,
	sampler_parameter: goose.Sampler_Binding,
	texture:           Texture_Handle,
	sampler:           Sampler_Handle,
}

Material :: struct {
	pipeline: Pipeline_Handle,
	textures: [dynamic]Material_Texture_Binding,
	tint:     [4]f32,
}

material_create :: proc(pipeline: Pipeline_Handle, tint := [4]f32{1, 1, 1, 1}) -> Material {
	assert(Resource_Handle(pipeline).generation != 0)
	return {pipeline = pipeline, tint = tint}
}

material_bind_texture :: proc(
	material: ^Material,
	texture_parameter: goose.Texture_Binding,
	sampler_parameter: goose.Sampler_Binding,
	texture: Texture_Handle,
	sampler: Sampler_Handle,
) {
	assert(texture_parameter.stage == sampler_parameter.stage)
	assert(Resource_Handle(texture).generation != 0)
	assert(Resource_Handle(sampler).generation != 0)
	for &binding in material.textures {
		if binding.texture_parameter == texture_parameter {
			binding = {texture_parameter, sampler_parameter, texture, sampler}
			return
		}
	}
	append(
		&material.textures,
		Material_Texture_Binding{texture_parameter, sampler_parameter, texture, sampler},
	)
}

material_find_texture :: proc(
	material: ^Material,
	parameter: goose.Texture_Binding,
) -> (
	^Material_Texture_Binding,
	bool,
) {
	for &binding in material.textures {
		if binding.texture_parameter == parameter do return &binding, true
	}
	return nil, false
}

material_destroy :: proc(material: ^Material) {
	delete(material.textures)
	material^ = {}
}
