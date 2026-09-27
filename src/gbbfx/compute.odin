package gbbfx

import goose "../goose"
import goose_sdl "../goose/adapters/sdl_gpu"
import sdl "vendor:sdl3"

Compute_Pipeline :: struct {
	handle: ^sdl.GPUComputePipeline,
}

gfx_compute_pipeline_create :: proc(
	gfx: ^Gfx,
	parameters: goose.Compute_Parameters,
) -> Compute_Pipeline_Handle {
	resource := Compute_Pipeline {
		handle = goose_sdl.create_compute_pipeline(gfx.gpu, parameters),
	}
	assert(resource.handle != nil)
	handle := Compute_Pipeline_Handle(handle_pool_acquire(&gfx.compute_pipeline_handles))
	index := Resource_Handle(handle).index
	if int(index) == len(gfx.compute_pipelines) {
		append(&gfx.compute_pipelines, resource)
	} else {
		gfx.compute_pipelines[index] = resource
	}
	return handle
}

gfx_compute_pipeline_get :: proc(gfx: ^Gfx, handle: Compute_Pipeline_Handle) -> ^Compute_Pipeline {
	raw := Resource_Handle(handle)
	assert(handle_pool_contains(&gfx.compute_pipeline_handles, raw), "stale compute pipeline handle")
	return &gfx.compute_pipelines[raw.index]
}

gfx_compute_pipeline_destroy :: proc(gfx: ^Gfx, handle: Compute_Pipeline_Handle) {
	raw := Resource_Handle(handle)
	if !handle_pool_contains(&gfx.compute_pipeline_handles, raw) do return
	resource := &gfx.compute_pipelines[raw.index]
	if resource.handle != nil do sdl.ReleaseGPUComputePipeline(gfx.gpu, resource.handle)
	resource^ = {}
	assert(handle_pool_release(&gfx.compute_pipeline_handles, raw))
}

// Dispatches compute work on the frame command buffer (between begin_frame
// and end_frame, outside any render pass). SDL rule: read-write storage
// textures are bound when the pass begins; sampled textures bind with a
// sampler after the pipeline.
gfx_compute_dispatch :: proc(
	gfx: ^Gfx,
	pipeline: Compute_Pipeline_Handle,
	write_textures: []Texture_Handle,
	sampled_textures: []Texture_Handle,
	sampler: Sampler_Handle,
	groups: [3]u32,
) {
	assert(gfx.frame_open && gfx.command_buffer != nil)

	rw_bindings := make(
		[]sdl.GPUStorageTextureReadWriteBinding,
		len(write_textures),
		context.temp_allocator,
	)
	for handle, index in write_textures {
		rw_bindings[index] = {texture = gfx_texture_get(gfx, handle).handle}
	}
	pass := sdl.BeginGPUComputePass(
		gfx.command_buffer,
		raw_data(rw_bindings),
		u32(len(rw_bindings)),
		nil,
		0,
	)
	assert(pass != nil)

	sdl.BindGPUComputePipeline(pass, gfx_compute_pipeline_get(gfx, pipeline).handle)

	if len(sampled_textures) > 0 {
		bindings := make(
			[]sdl.GPUTextureSamplerBinding,
			len(sampled_textures),
			context.temp_allocator,
		)
		for handle, index in sampled_textures {
			bindings[index] = {
				texture = gfx_texture_get(gfx, handle).handle,
				sampler = gfx_sampler_get(gfx, sampler).handle,
			}
		}
		sdl.BindGPUComputeSamplers(pass, 0, raw_data(bindings), u32(len(bindings)))
	}

	sdl.DispatchGPUCompute(pass, groups.x, groups.y, groups.z)
	sdl.EndGPUComputePass(pass)
}
