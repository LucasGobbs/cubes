package main
import sdl "vendor:sdl3"


Material :: struct {
	texture:  Texture,
	sampler:  ^sdl.GPUSampler,
	pipeline: ^sdl.GPUGraphicsPipeline,
}
