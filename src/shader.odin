package main
import "core:log"
import sdl "vendor:sdl3"
load_shader :: proc(
	$filepath: string,
	gpu: ^sdl.GPUDevice,
	stage: sdl.GPUShaderStage,
	num_uniform_buffers: u32,
	num_samplers: u32,
) -> ^sdl.GPUShader {

	shader_code := #load(filepath)
	shader := sdl.CreateGPUShader(
		gpu,
		{
			code = raw_data(shader_code),
			code_size = len(shader_code),
			entrypoint = stage == .VERTEX ? "vertexMain" : "pixelMain",
			format = {.MSL},
			stage = stage,
			num_uniform_buffers = num_uniform_buffers,
			num_samplers = num_samplers,
		},
	)
	if shader == nil {
		log.error("Error creating shader: ", filepath, string(sdl.GetError()))
	}

	return shader
}
