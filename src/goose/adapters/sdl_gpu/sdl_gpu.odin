package sdl_gpu

import goose "../.."
import "core:log"
import sdl "vendor:sdl3"

shader_format :: proc(format: goose.Code_Format) -> sdl.GPUShaderFormat {
	#partial switch format {
	case .Metal_Source:
		return {.MSL}
	case .Spirv:
		return {.SPIRV}
	}
	return {}
}

create_graphics_shader :: proc(
	gpu: ^sdl.GPUDevice,
	parameters: goose.Graphics_Parameters,
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
	parameters: goose.Compute_Parameters,
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

vertex_format :: proc(format: goose.Vertex_Format) -> sdl.GPUVertexElementFormat {
	#partial switch format {
	case .Int:
		return .INT
	case .Int2:
		return .INT2
	case .Int3:
		return .INT3
	case .Int4:
		return .INT4
	case .Uint:
		return .UINT
	case .Uint2:
		return .UINT2
	case .Uint3:
		return .UINT3
	case .Uint4:
		return .UINT4
	case .Float:
		return .FLOAT
	case .Float2:
		return .FLOAT2
	case .Float3:
		return .FLOAT3
	case .Float4:
		return .FLOAT4
	case .Sint8x2:
		return .BYTE2
	case .Sint8x4:
		return .BYTE4
	case .Uint8x2:
		return .UBYTE2
	case .Uint8x4:
		return .UBYTE4
	case .Snorm8x2:
		return .BYTE2_NORM
	case .Snorm8x4:
		return .BYTE4_NORM
	case .Unorm8x2:
		return .UBYTE2_NORM
	case .Unorm8x4:
		return .UBYTE4_NORM
	case .Sint16x2:
		return .SHORT2
	case .Sint16x4:
		return .SHORT4
	case .Uint16x2:
		return .USHORT2
	case .Uint16x4:
		return .USHORT4
	case .Snorm16x2:
		return .SHORT2_NORM
	case .Snorm16x4:
		return .SHORT4_NORM
	case .Unorm16x2:
		return .USHORT2_NORM
	case .Unorm16x4:
		return .USHORT4_NORM
	case .Float16x2:
		return .HALF2
	case .Float16x4:
		return .HALF4
	}
	return .INVALID
}

convert_vertex_attributes :: proc(
	attributes: []goose.Vertex_Attribute,
	allocator := context.allocator,
) -> []sdl.GPUVertexAttribute {
	result := make([]sdl.GPUVertexAttribute, len(attributes), allocator)
	for attribute, index in attributes {
		format := vertex_format(attribute.format)
		assert(format != .INVALID, "Goose vertex format is unsupported by SDL GPU")
		result[index] = {
			location    = attribute.location,
			buffer_slot = attribute.buffer_slot,
			format      = format,
			offset      = attribute.offset,
		}
	}
	return result
}

push_uniform :: proc(
	command_buffer: ^sdl.GPUCommandBuffer,
	binding: goose.Uniform_Block,
	data: ^$T,
) {
	assert(command_buffer != nil)
	assert(size_of(T) == binding.size)
	switch binding.stage {
	case .Vertex:
		sdl.PushGPUVertexUniformData(command_buffer, binding.location.slot, data, binding.size)
	case .Fragment:
		sdl.PushGPUFragmentUniformData(command_buffer, binding.location.slot, data, binding.size)
	case .Compute:
		sdl.PushGPUComputeUniformData(command_buffer, binding.location.slot, data, binding.size)
	}
}

bind_sampler :: proc(
	pass: ^sdl.GPURenderPass,
	texture_binding: goose.Texture_Binding,
	sampler_binding: goose.Sampler_Binding,
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
