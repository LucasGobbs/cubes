package shader

import "core:log"
import sdl "vendor:sdl3"

Graphics_Stage :: enum {
	Vertex,
	Fragment,
}

Vertex_Attribute :: sdl.GPUVertexAttribute
Command_Buffer :: sdl.GPUCommandBuffer

push_graphics_uniform :: proc(
	command_buffer: ^Command_Buffer,
	stage: Graphics_Stage,
	slot: u32,
	data: ^$T,
) {
	assert(command_buffer != nil)
	if stage == .Vertex {
		sdl.PushGPUVertexUniformData(command_buffer, slot, data, u32(size_of(T)))
	} else {
		sdl.PushGPUFragmentUniformData(command_buffer, slot, data, u32(size_of(T)))
	}
}

push_compute_uniform :: proc(command_buffer: ^Command_Buffer, slot: u32, data: ^$T) {
	assert(command_buffer != nil)
	sdl.PushGPUComputeUniformData(command_buffer, slot, data, u32(size_of(T)))
}

Blob :: struct {
	data: [^]u8,
	size: uint,
}

Code :: struct {
	name:       string,
	entrypoint: cstring,
	metal:      Blob,
	spirv:      Blob,
}

Graphics_Resource_Counts :: struct {
	samplers:         u32,
	storage_textures: u32,
	storage_buffers:  u32,
	uniform_buffers:  u32,
}

Graphics_Parameters :: struct {
	code:      Code,
	stage:     Graphics_Stage,
	resources: Graphics_Resource_Counts,
}

Compute_Resource_Counts :: struct {
	samplers:                   u32,
	readonly_storage_textures:  u32,
	readonly_storage_buffers:   u32,
	readwrite_storage_textures: u32,
	readwrite_storage_buffers:  u32,
	uniform_buffers:            u32,
}

Compute_Parameters :: struct {
	code:         Code,
	resources:    Compute_Resource_Counts,
	thread_count: [3]u32,
}

create_graphics :: proc(gpu: ^sdl.GPUDevice, parameters: Graphics_Parameters) -> ^sdl.GPUShader {
	assert(gpu != nil)
	blob, format, ok := select_code(parameters.code, sdl.GetGPUShaderFormats(gpu))
	if !ok {
		log.error("No compatible Metal or SPIR-V code for shader: ", parameters.code.name)
		return nil
	}

	stage := sdl.GPUShaderStage.VERTEX
	if parameters.stage == .Fragment do stage = .FRAGMENT

	shader := sdl.CreateGPUShader(
		gpu,
		{
			code = blob.data,
			code_size = blob.size,
			entrypoint = parameters.code.entrypoint,
			format = format,
			stage = stage,
			num_samplers = parameters.resources.samplers,
			num_storage_textures = parameters.resources.storage_textures,
			num_storage_buffers = parameters.resources.storage_buffers,
			num_uniform_buffers = parameters.resources.uniform_buffers,
		},
	)
	if shader == nil {
		log.error("Failed to create shader ", parameters.code.name, ": ", string(sdl.GetError()))
	}
	return shader
}

create_compute :: proc(
	gpu: ^sdl.GPUDevice,
	parameters: Compute_Parameters,
) -> ^sdl.GPUComputePipeline {
	assert(gpu != nil)
	blob, format, ok := select_code(parameters.code, sdl.GetGPUShaderFormats(gpu))
	if !ok {
		log.error("No compatible Metal or SPIR-V code for compute shader: ", parameters.code.name)
		return nil
	}

	resources := parameters.resources
	pipeline := sdl.CreateGPUComputePipeline(
		gpu,
		{
			code = blob.data,
			code_size = blob.size,
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
	if pipeline == nil {
		log.error(
			"Failed to create compute shader ",
			parameters.code.name,
			": ",
			string(sdl.GetError()),
		)
	}
	return pipeline
}

select_code :: proc(
	code: Code,
	formats: sdl.GPUShaderFormat,
) -> (
	blob: Blob,
	format: sdl.GPUShaderFormat,
	ok: bool,
) {
	if .MSL in formats && code.metal.size > 0 {
		return code.metal, {.MSL}, true
	}
	if .SPIRV in formats && code.spirv.size > 0 {
		return code.spirv, {.SPIRV}, true
	}
	return {}, {}, false
}
