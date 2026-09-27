package main
import sdl "vendor:sdl3"


Material :: struct {
	texture:  Texture,
	sampler:  ^sdl.GPUSampler,
	pipeline: ^Pipeline,
}

material_destroy :: proc(gfx: ^Gfx, material: ^Material) {
	// Texture is owned by Material. Pipeline and sampler are borrowed.
	texture_destroy(gfx, &material.texture)
	material^ = {}
}
