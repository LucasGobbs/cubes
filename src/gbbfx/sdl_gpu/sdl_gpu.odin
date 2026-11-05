package sdl_gpu

import goose "../../../third_party/goose/src"
import "core:log"
import sdl "vendor:sdl3"

shader_format :: proc(format: goose.CodeFormat) -> sdl.GPUShaderFormat {
	#partial switch format {
	case .MetalSource:
		return {.MSL}
	case .Spirv:
		return {.SPIRV}
	}
	return {}
}

create_graphics_shader :: proc(
	gpu: ^sdl.GPUDevice,
	parameters: goose.GraphicsParameters,
) -> ^sdl.GPUShader {
	assert(gpu != nil)
	assert(parameters.stage == .Vertex || parameters.stage == .Fragment)
	format := shader_format(parameters.code.format)
	if format == {} || sdl.GetGPUShaderFormats(gpu) & format == {} {
		log.error(
			"Goose shader platform is unsupported by the SDL GPU device: ",
			parameters.code.name,
		)
		return nil
	}

	stage := sdl.GPUShaderStage.VERTEX
	if parameters.stage == .Fragment do stage = .FRAGMENT
	resources := parameters.resources
	result := sdl.CreateGPUShader(
		gpu,
		{
			code = parameters.code.blob.data,
			code_size = parameters.code.blob.size,
			entrypoint = parameters.code.entrypoint,
			format = format,
			stage = stage,
			num_samplers = resources.samplers,
			num_storage_textures = resources.storage_textures,
			num_storage_buffers = resources.storage_buffers,
			num_uniform_buffers = resources.uniform_buffers,
		},
	)
	if result == nil {
		log.error(
			"Failed to create Goose graphics shader ",
			parameters.code.name,
			": ",
			string(sdl.GetError()),
		)
	}
	return result
}

create_compute_pipeline :: proc(
	gpu: ^sdl.GPUDevice,
	parameters: goose.ComputeParameters,
) -> ^sdl.GPUComputePipeline {
	assert(gpu != nil)
	format := shader_format(parameters.code.format)
	if format == {} || sdl.GetGPUShaderFormats(gpu) & format == {} {
		log.error(
			"Goose compute platform is unsupported by the SDL GPU device: ",
			parameters.code.name,
		)
		return nil
	}

	resources := parameters.resources
	result := sdl.CreateGPUComputePipeline(
		gpu,
		{
			code = parameters.code.blob.data,
			code_size = parameters.code.blob.size,
			entrypoint = parameters.code.entrypoint,
			format = format,
			num_samplers = resources.samplers,
			num_readonly_storage_textures = resources.readonly_storage_textures,
			num_readonly_storage_buffers = resources.readonly_storage_buffers,
			num_readwrite_storage_textures = resources.readwrite_storage_textures,
			num_readwrite_storage_buffers = resources.readwrite_storage_buffers,
			num_uniform_buffers = resources.uniform_buffers,
			threadcount_x = parameters.thread_count.x,
			threadcount_y = parameters.thread_count.y,
			threadcount_z = parameters.thread_count.z,
		},
	)
	if result == nil {
		log.error(
			"Failed to create Goose compute pipeline ",
			parameters.code.name,
			": ",
			string(sdl.GetError()),
		)
	}
	return result
}

push_uniform_data :: proc(
	command_buffer: ^sdl.GPUCommandBuffer,
	binding: goose.UniformBlock,
	data: rawptr,
	size: u32,
) {
	assert(command_buffer != nil && data != nil)
	assert(size == binding.size)
	switch binding.stage {
	case .Vertex:
		sdl.PushGPUVertexUniformData(command_buffer, binding.location.slot, data, size)
	case .Fragment:
		sdl.PushGPUFragmentUniformData(command_buffer, binding.location.slot, data, size)
	case .Compute:
		sdl.PushGPUComputeUniformData(command_buffer, binding.location.slot, data, size)
	}
}

push_uniform :: proc(
	command_buffer: ^sdl.GPUCommandBuffer,
	binding: goose.UniformBlock,
	data: ^$T,
) {
	assert(size_of(T) == binding.size)
	push_uniform_data(command_buffer, binding, rawptr(data), binding.size)
}

bind_sampler :: proc(
	pass: ^sdl.GPURenderPass,
	texture_binding: goose.TextureBinding,
	sampler_binding: goose.SamplerBinding,
	texture: ^sdl.GPUTexture,
	sampler: ^sdl.GPUSampler,
) {
	assert(pass != nil && texture != nil && sampler != nil)
	assert(texture_binding.stage == sampler_binding.stage)
	assert(texture_binding.location.slot == sampler_binding.location.slot)
	sdl_binding := sdl.GPUTextureSamplerBinding {
		texture = texture,
		sampler = sampler,
	}
	switch texture_binding.stage {
	case .Vertex:
		sdl.BindGPUVertexSamplers(pass, texture_binding.location.slot, &sdl_binding, 1)
	case .Fragment:
		sdl.BindGPUFragmentSamplers(pass, texture_binding.location.slot, &sdl_binding, 1)
	case .Compute:
		assert(false, "Compute samplers are bound when beginning an SDL GPU compute pass")
	}
}
