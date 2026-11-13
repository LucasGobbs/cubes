package gfx

import goose "../../../third_party/goose/src"
import "core:mem"
import sdl "vendor:sdl3"

Material_Texture_Binding :: struct {
	texture_parameter: goose.TextureBinding,
	sampler_parameter: goose.SamplerBinding,
	texture:           Texture_Handle,
	sampler:           Sampler_Handle,
}

Material_Uniform_Binding :: struct {
	parameter: goose.UniformBlock,
	data:      []byte,
}

Material :: struct {
	pipeline: Pipeline_Handle,
	textures: [dynamic]Material_Texture_Binding,
	uniforms: [dynamic]Material_Uniform_Binding,
}

Material_Kind :: enum u8 {
	Textured,
	Unlit,
	Textured_Instanced,
	Textured_Skinned,
}

// Zero value = trilinear. Presets are created once per Device, paused from scenes.
Sampler_Preset :: enum u8 {
	Trilinear,
	Linear_Clamp,
	Nearest_Clamp,
}

// A path is loaded into the open scope; a handle is used as-is.
Texture_Source :: union {
	string,
	Texture_Handle,
}

Material_Desc :: struct {
	kind:    Material_Kind,
	texture: Texture_Source, // required for textured kinds
	sampler: Sampler_Preset,
	tint:    [4]f32, // Unlit only; zero = white
}

// Low-level: wraps a custom pipeline. Caller owns it; call material_destroy.
material_make :: proc(pipeline: Pipeline_Handle) -> Material {
	assert(Resource_Handle(pipeline).generation != 0)
	return {pipeline = pipeline}
}

// Scope-owned: freed by scope_end. Scenes never call material_destroy.
material_create :: proc(gfx_ctx: ^Device, desc: Material_Desc) -> ^Material {
	material := new(Material)
	material^ = material_make(builtin_material_pipeline(gfx_ctx, desc.kind))
	tint := desc.tint
	if tint == {} do tint = {1, 1, 1, 1}
	material_bind_kind(
		gfx_ctx,
		material,
		desc.kind,
		resolve_texture(gfx_ctx, desc.texture),
		desc.sampler,
		tint,
	)
	scope_defer(gfx_ctx, material_release, material)
	return material
}

@(private)
material_release :: proc(gfx_ctx: ^Device, user: rawptr) {
	material := (^Material)(user)
	material_destroy(material)
	free(material)
}

// Shared by material_create and model_add.
material_bind_kind :: proc(
	gfx_ctx: ^Device,
	material: ^Material,
	kind: Material_Kind,
	texture: Texture_Handle,
	sampler: Sampler_Preset,
	tint: [4]f32,
) {
	s := builtin_sampler(gfx_ctx, sampler)
	switch kind {
	case .Textured:           bind_textured_material(material, texture, s)
	case .Textured_Instanced: bind_textured_instanced_material(material, texture, s)
	case .Textured_Skinned:   bind_textured_skinned_material(material, texture, s)
	case .Unlit:              set_unlit_color(material, tint)
	}
}

resolve_texture :: proc(gfx_ctx: ^Device, source: Texture_Source) -> Texture_Handle {
	switch s in source {
	case nil:            return {}
	case string:         return texture_load(gfx_ctx, s)
	case Texture_Handle: return s
	}
	return {}
}

// Cached for the Device lifetime. Paused so no scene scope owns it; gfx.destroy sweeps it.
builtin_material_pipeline :: proc(gfx_ctx: ^Device, kind: Material_Kind) -> Pipeline_Handle {
	slot := &gfx_ctx.material_pipelines[kind]
	if Resource_Handle(slot^).generation == 0 {
		gfx_ctx.scope_paused += 1
		defer gfx_ctx.scope_paused -= 1
		switch kind {
		case .Textured:           slot^ = create_textured_pipeline(gfx_ctx)
		case .Unlit:              slot^ = create_unlit_pipeline(gfx_ctx)
		case .Textured_Instanced: slot^ = create_textured_instanced_pipeline(gfx_ctx)
		case .Textured_Skinned:   slot^ = create_textured_skinned_pipeline(gfx_ctx)
		}
	}
	return slot^
}

builtin_sampler :: proc(gfx_ctx: ^Device, preset: Sampler_Preset) -> Sampler_Handle {
	slot := &gfx_ctx.material_samplers[preset]
	if Resource_Handle(slot^).generation == 0 {
		gfx_ctx.scope_paused += 1
		defer gfx_ctx.scope_paused -= 1
		info: sdl.GPUSamplerCreateInfo
		switch preset {
		case .Trilinear:     info = SAMPLER_TRILINEAR
		case .Linear_Clamp:  info = SAMPLER_LINEAR_CLAMP
		case .Nearest_Clamp: info = SAMPLER_NEAREST_CLAMP
		}
		slot^ = sampler_create(gfx_ctx, info)
	}
	return slot^
}

material_bind_texture :: proc(
	material: ^Material,
	texture_parameter: goose.TextureBinding,
	sampler_parameter: goose.SamplerBinding,
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

material_set_uniform :: proc(material: ^Material, parameter: goose.UniformBlock, data: ^$T) {
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
	parameter: goose.UniformBlock,
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
