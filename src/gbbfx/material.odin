package gbbfx

import goose "../goose"
import "core:mem"

Material_Texture_Binding :: struct {
	texture_parameter: goose.Texture_Binding,
	sampler_parameter: goose.Sampler_Binding,
	texture:           Texture_Handle,
	sampler:           Sampler_Handle,
}

Material_Uniform_Binding :: struct {
	parameter: goose.Uniform_Block,
	data:      []byte,
}

Material :: struct {
	pipeline: Pipeline_Handle,
	textures: [dynamic]Material_Texture_Binding,
	uniforms: [dynamic]Material_Uniform_Binding,
}

material_create :: proc(pipeline: Pipeline_Handle) -> Material {
	assert(Resource_Handle(pipeline).generation != 0)
	return {pipeline = pipeline}
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

material_set_uniform :: proc(material: ^Material, parameter: goose.Uniform_Block, data: ^$T) {
	assert(size_of(T) == parameter.size)
	for &binding in material.uniforms {
		if binding.parameter == parameter {
			mem.copy(raw_data(binding.data), data, int(parameter.size))
			return
		}
	}
	bytes := make([]byte, int(parameter.size))
	mem.copy(raw_data(bytes), data, int(parameter.size))
	append(&material.uniforms, Material_Uniform_Binding{parameter = parameter, data = bytes})
}

material_uniform_data :: proc(
	material: ^Material,
	parameter: goose.Uniform_Block,
) -> (
	[]byte,
	bool,
) {
	for &binding in material.uniforms {
		if binding.parameter == parameter do return binding.data, true
	}
	return nil, false
}

material_destroy :: proc(material: ^Material) {
	for &binding in material.uniforms do delete(binding.data)
	delete(material.uniforms)
	delete(material.textures)
	material^ = {}
}
