package gfx

import goose "../../../third_party/goose/src"
import goose_sdl "sdl_gpu"
import sdl "vendor:sdl3"

Compute_Pipeline :: struct {
	handle: ^sdl.GPUComputePipeline,
}

gfx_compute_pipeline_create :: proc(
	dev: ^Device,
	parameters: goose.ComputeParameters,
) -> Compute_Pipeline_Handle {
	resource := Compute_Pipeline {
		handle = goose_sdl.create_compute_pipeline(dev.gpu, parameters),
	}
	assert(resource.handle != nil)
	handle := Compute_Pipeline_Handle(handle_pool_acquire(&dev.compute_pipeline_handles))
	index := Resource_Handle(handle).index
	if int(index) == len(dev.compute_pipelines) {
		append(&dev.compute_pipelines, resource)
	} else {
		dev.compute_pipelines[index] = resource
	}
	return handle
}

gfx_compute_pipeline_get :: proc(dev: ^Device, handle: Compute_Pipeline_Handle) -> ^Compute_Pipeline {
	raw := Resource_Handle(handle)
	assert(handle_pool_contains(&dev.compute_pipeline_handles, raw), "stale compute pipeline handle")
	return &dev.compute_pipelines[raw.index]
}

gfx_compute_pipeline_destroy :: proc(dev: ^Device, handle: Compute_Pipeline_Handle) {
	raw := Resource_Handle(handle)
	if !handle_pool_contains(&dev.compute_pipeline_handles, raw) do return
	resource := &dev.compute_pipelines[raw.index]
	if resource.handle != nil do sdl.ReleaseGPUComputePipeline(dev.gpu, resource.handle)
	resource^ = {}
	assert(handle_pool_release(&dev.compute_pipeline_handles, raw))
}

// Dispatches compute work on the frame command buffer (between begin_frame
// and end_frame, outside any render pass). SDL rule: read-write storage
// textures are bound when the pass begins; sampled textures bind with a
// sampler after the pipeline.
gfx_compute_dispatch :: proc(
	dev: ^Device,
	pipeline: Compute_Pipeline_Handle,
	write_textures: []Texture_Handle,
	sampled_textures: []Texture_Handle,
	sampler: Sampler_Handle,
	groups: [3]u32,
	uniform_data: []byte = nil,
) {
	assert(dev.frame_open && dev.command_buffer != nil)

	rw_bindings := make(
		[]sdl.GPUStorageTextureReadWriteBinding,
		len(write_textures),
		context.temp_allocator,
	)
	for handle, index in write_textures {
		rw_bindings[index] = {texture = gfx_texture_get(dev, handle).handle}
	}
	pass := sdl.BeginGPUComputePass(
		dev.command_buffer,
		raw_data(rw_bindings),
		u32(len(rw_bindings)),
		nil,
		0,
	)
	assert(pass != nil)

	sdl.BindGPUComputePipeline(pass, gfx_compute_pipeline_get(dev, pipeline).handle)
	if len(uniform_data) > 0 {
		sdl.PushGPUComputeUniformData(dev.command_buffer, 0, raw_data(uniform_data), u32(len(uniform_data)))
	}

	if len(sampled_textures) > 0 {
		bindings := make(
			[]sdl.GPUTextureSamplerBinding,
			len(sampled_textures),
			context.temp_allocator,
		)
		for handle, index in sampled_textures {
			bindings[index] = {
				texture = gfx_texture_get(dev, handle).handle,
				sampler = gfx_sampler_get(dev, sampler).handle,
			}
		}
		sdl.BindGPUComputeSamplers(pass, 0, raw_data(bindings), u32(len(bindings)))
	}

	sdl.DispatchGPUCompute(pass, groups.x, groups.y, groups.z)
	sdl.EndGPUComputePass(pass)
}
