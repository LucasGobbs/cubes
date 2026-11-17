package gfx

import goose "../../../third_party/goose/src"
import goose_sdl "sdl_gpu"
import sdl "vendor:sdl3"

Compute_Pipeline :: struct {
	handle: ^sdl.GPUComputePipeline,
}

compute_pipeline_create :: proc(
	gfx_ctx: ^Device,
	parameters: goose.ComputeParameters,
) -> Compute_Pipeline_Handle {
	resource := Compute_Pipeline {
		handle = goose_sdl.create_compute_pipeline(gfx_ctx.gpu, parameters),
	}
	assert(resource.handle != nil)
	handle := Compute_Pipeline_Handle(handle_pool_acquire(&gfx_ctx.compute_pipeline_handles))
	index := Resource_Handle(handle).index
	if int(index) == len(gfx_ctx.compute_pipelines) {
		append(&gfx_ctx.compute_pipelines, resource)
	} else {
		gfx_ctx.compute_pipelines[index] = resource
	}
	scope_track(gfx_ctx, .Compute_Pipeline, Resource_Handle(handle))
	return handle
}

compute_pipeline_get :: proc(gfx_ctx: ^Device, handle: Compute_Pipeline_Handle) -> ^Compute_Pipeline {
	raw := Resource_Handle(handle)
	assert(handle_pool_contains(&gfx_ctx.compute_pipeline_handles, raw), "stale compute pipeline handle")
	return &gfx_ctx.compute_pipelines[raw.index]
}

compute_pipeline_destroy :: proc(gfx_ctx: ^Device, handle: Compute_Pipeline_Handle) {
	raw := Resource_Handle(handle)
	if !handle_pool_contains(&gfx_ctx.compute_pipeline_handles, raw) do return
	scope_untrack(gfx_ctx, .Compute_Pipeline, raw)
	resource := &gfx_ctx.compute_pipelines[raw.index]
	if resource.handle != nil do sdl.ReleaseGPUComputePipeline(gfx_ctx.gpu, resource.handle)
	resource^ = {}
	assert(handle_pool_release(&gfx_ctx.compute_pipeline_handles, raw))
}

// Dispatches compute work outside any render pass. SDL rule: read-write storage
// textures and buffers bind when the pass begins; read-only buffers and sampled
// textures bind after the pipeline.
compute_dispatch :: proc(
	gfx_ctx: ^Device,
	pipeline: Compute_Pipeline_Handle,
	write_textures: []Texture_Handle,
	sampled_textures: []Texture_Handle,
	sampler: Sampler_Handle,
	groups: [3]u32,
	uniform_data: []byte = nil,
	readonly_buffers: []Buffer_Handle = nil,
	readwrite_buffers: []Buffer_Handle = nil,
) {
	assert(gfx_ctx.frame_open && gfx_ctx.command_buffer != nil)

	rw_bindings := make(
		[]sdl.GPUStorageTextureReadWriteBinding,
		len(write_textures),
		context.temp_allocator,
	)
	for handle, index in write_textures {
		rw_bindings[index] = {texture = texture_get(gfx_ctx, handle).handle}
	}
	rw_buffer_bindings := make(
		[]sdl.GPUStorageBufferReadWriteBinding,
		len(readwrite_buffers),
		context.temp_allocator,
	)
	for handle, index in readwrite_buffers {
		rw_buffer_bindings[index] = {buffer = buffer_get(gfx_ctx, handle).handle}
	}
	pass := sdl.BeginGPUComputePass(
		gfx_ctx.command_buffer,
		raw_data(rw_bindings),
		u32(len(rw_bindings)),
		raw_data(rw_buffer_bindings),
		u32(len(rw_buffer_bindings)),
	)
	assert(pass != nil)

	sdl.BindGPUComputePipeline(pass, compute_pipeline_get(gfx_ctx, pipeline).handle)

	if len(readonly_buffers) > 0 {
		handles := make([]^sdl.GPUBuffer, len(readonly_buffers), context.temp_allocator)
		for handle, index in readonly_buffers {
			handles[index] = buffer_get(gfx_ctx, handle).handle
		}
		sdl.BindGPUComputeStorageBuffers(pass, 0, raw_data(handles), u32(len(handles)))
	}

	if len(uniform_data) > 0 {
		sdl.PushGPUComputeUniformData(gfx_ctx.command_buffer, 0, raw_data(uniform_data), u32(len(uniform_data)))
	}

	if len(sampled_textures) > 0 {
		bindings := make(
			[]sdl.GPUTextureSamplerBinding,
			len(sampled_textures),
			context.temp_allocator,
		)
		for handle, index in sampled_textures {
			bindings[index] = {
				texture = texture_get(gfx_ctx, handle).handle,
				sampler = sampler_get(gfx_ctx, sampler).handle,
			}
		}
		sdl.BindGPUComputeSamplers(pass, 0, raw_data(bindings), u32(len(bindings)))
	}

	sdl.DispatchGPUCompute(pass, groups.x, groups.y, groups.z)
	sdl.EndGPUComputePass(pass)
}
