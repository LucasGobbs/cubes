package particles

import gfx "../gfx"
import goose_sdl "../gfx/sdl_gpu"
import "core:mem"
import sdl "vendor:sdl3"

// Must match the thread count in particle_sim.slang.
THREAD_GROUP_SIZE :: 64

Emitter_Handle :: struct {
	index:      u32,
	generation: u32,
}

System :: struct {
	renderer:        ^gfx.Renderer,
	sim:             gfx.Compute_Pipeline_Handle,
	render_additive: gfx.Pipeline_Handle,
	render_alpha:    gfx.Pipeline_Handle,
	emitters:        [dynamic]Emitter,
	free_slots:      [dynamic]u32,
	// The GPU sim integrates in the before hook, which has no dt of its own.
	dt:              f32,
}

system_create :: proc(renderer: ^gfx.Renderer) -> ^System {
	system := new(System)
	system.renderer = renderer
	gfx_ctx := renderer.gfx_ctx
	system.sim = gfx.compute_pipeline_create(gfx_ctx, gfx.default_particle_sim_compute())
	system.render_additive = gfx.pipeline_create(gfx_ctx, particle_pipeline_desc(.Additive))
	system.render_alpha = gfx.pipeline_create(gfx_ctx, particle_pipeline_desc(.Alpha))
	gfx.renderer_add_scene_hook(
		renderer,
		gfx.Scene_Hook{name = "particles", before = particles_before, draw = particles_draw, user = system},
	)
	return system
}

// Scene-pass pipelines take the default color format, which matches scene_color.
particle_pipeline_desc :: proc(blend: Blend) -> gfx.Graphics_Pipeline_Desc {
	return gfx.Graphics_Pipeline_Desc {
		vertex = gfx.default_particle_render_vertex(),
		fragment = gfx.default_particle_render_fragment(),
		depth_test = true,
		additive = blend == .Additive,
		blend = blend == .Alpha,
	}
}

system_destroy :: proc(system: ^System) {
	gfx_ctx := system.renderer.gfx_ctx
	gfx.renderer_remove_scene_hook(system.renderer, system)
	_ = sdl.WaitForGPUIdle(gfx_ctx.gpu) // in-flight frames still read buffers and pipelines
	for &e in system.emitters {
		if !e.alive do continue
		gfx.buffer_destroy(gfx_ctx, e.buffer)
		emitter_destroy(&e)
	}
	delete(system.emitters)
	delete(system.free_slots)
	gfx.pipeline_destroy(gfx_ctx, system.render_additive)
	gfx.pipeline_destroy(gfx_ctx, system.render_alpha)
	gfx.compute_pipeline_destroy(gfx_ctx, system.sim)
	free(system)
}

emitter_add :: proc(system: ^System, desc: Emitter_Desc) -> Emitter_Handle {
	gfx_ctx := system.renderer.gfx_ctx
	slot: u32
	if len(system.free_slots) > 0 {
		slot = pop(&system.free_slots)
	} else {
		append(&system.emitters, Emitter{})
		slot = u32(len(system.emitters) - 1)
	}
	e := &system.emitters[slot]
	// emitter_init resets the whole struct, so the generation is carried across it.
	generation := e.generation + 1
	emitter_init(e, desc)
	e.generation = generation

	usage := sdl.GPUBufferUsageFlags{.GRAPHICS_STORAGE_READ}
	if e.desc.mode == .GPU do usage += {.COMPUTE_STORAGE_WRITE}
	// Zero memory is dead, so an unuploaded buffer would show garbage particles on the first frame.
	e.buffer = gfx.buffer_create_zeroed(gfx_ctx, e.desc.capacity * u32(size_of(Particle)), usage)
	gfx.uploader_begin(&system.renderer.uploader)
	gfx.uploader_upload_buffer(&system.renderer.uploader, e.buffer)
	gfx.uploader_flush(&system.renderer.uploader)
	staged := gfx.buffer_get(gfx_ctx, e.buffer)
	delete(staged._temporary_raw_data)
	staged._temporary_raw_data = nil

	return Emitter_Handle{index = slot, generation = generation}
}

emitter_remove :: proc(system: ^System, handle: Emitter_Handle) {
	e := emitter_get(system, handle)
	if e == nil do return
	gfx_ctx := system.renderer.gfx_ctx
	_ = sdl.WaitForGPUIdle(gfx_ctx.gpu) // the GPU may still read the buffer
	gfx.buffer_destroy(gfx_ctx, e.buffer)
	emitter_destroy(e)
	generation := e.generation
	e^ = Emitter{generation = generation}
	append(&system.free_slots, handle.index)
}

emitter_get :: proc(system: ^System, handle: Emitter_Handle) -> ^Emitter {
	if handle.index >= u32(len(system.emitters)) do return nil
	e := &system.emitters[handle.index]
	if !e.alive || e.generation != handle.generation do return nil
	return e
}

system_update :: proc(system: ^System, dt: f32) {
	system.dt = dt
	for &e in system.emitters {
		if e.alive do emitter_step(&e, dt)
	}
}

particles_before :: proc(renderer: ^gfx.Renderer, user: rawptr) {
	system := (^System)(user)
	gfx_ctx := renderer.gfx_ctx
	for &e in system.emitters {
		if !e.alive do continue
		switch e.desc.mode {
		case .GPU:
			block := gfx.DefaultParticleSimComputeUniformBlock{}
			p := &block.params
			p.gravity = e.desc.gravity
			p.dt = system.dt
			p.drag = e.desc.drag
			p.capacity = e.desc.capacity
			p.spawn_start = e.spawn_start
			p.spawn_count = e.spawn_count
			p.origin = e.desc.position
			p.seed = e.frame
			p.direction = e.desc.direction
			p.spread = e.desc.spread
			p.life_min = e.desc.lifetime[0]
			p.life_max = e.desc.lifetime[1]
			p.speed_min = e.desc.speed[0]
			p.speed_max = e.desc.speed[1]
			p.color = e.desc.color_start
			p.radius = e.desc.radius
			groups := [3]u32{(e.desc.capacity + THREAD_GROUP_SIZE - 1) / THREAD_GROUP_SIZE, 1, 1}
			gfx.compute_dispatch(
				gfx_ctx,
				system.sim,
				nil,
				nil,
				gfx.Sampler_Handle{},
				groups,
				mem.ptr_to_bytes(&block),
				nil,
				[]gfx.Buffer_Handle{e.buffer},
			)
		case .CPU:
			e.buffer = gfx.buffer_stage(gfx_ctx, e.buffer, e.cpu, .GRAPHICS_STORAGE_READ)
			gfx.uploader_begin(&renderer.uploader)
			gfx.uploader_upload_buffer(&renderer.uploader, e.buffer)
			gfx.uploader_flush(&renderer.uploader)
			// The staged slice aliases the emitter's cpu array, so it is not ours to free.
			gfx.buffer_get(gfx_ctx, e.buffer)._temporary_raw_data = nil
		}
	}
}

particles_draw :: proc(renderer: ^gfx.Renderer, user: rawptr) {
	system := (^System)(user)
	gfx_ctx := renderer.gfx_ctx
	for &e in system.emitters {
		if !e.alive || !gfx.handle_pool_contains(&gfx_ctx.buffer_handles, gfx.Resource_Handle(e.buffer)) do continue

		pipeline_handle := system.render_alpha if e.desc.blend == .Alpha else system.render_additive
		pipeline := gfx.pipeline_get(gfx_ctx, pipeline_handle)
		gfx.pipeline_bind_native(renderer.pass, pipeline, renderer.pass_msaa)

		block := gfx.DefaultParticleRenderVertexUniformBlock{}
		p := &block.params
		p.view_projection = renderer.view_projection
		p.cam_right = renderer.camera.right
		p.cam_up = renderer.camera.up
		p.size_start = e.desc.size[0]
		p.size_end = e.desc.size[1]
		p.color_end = e.desc.color_end
		p.fade_in = e.desc.fade_in
		p.stretch_cam = {renderer.camera.position.x, renderer.camera.position.y, renderer.camera.position.z, e.desc.stretch}
		goose_sdl.push_uniform(gfx_ctx.command_buffer, gfx.DEFAULT_PARTICLE_RENDER_VERTEX_UNIFORM_BLOCK, &block)

		buffer := gfx.buffer_get(gfx_ctx, e.buffer)
		sdl.BindGPUVertexStorageBuffers(
			renderer.pass,
			gfx.DEFAULT_PARTICLE_RENDER_VERTEX_PARTICLES.location.slot,
			&buffer.handle,
			1,
		)
		// Dead slots are clipped in the vertex shader, so every slot gets its quad.
		sdl.DrawGPUPrimitives(renderer.pass, 6 * e.desc.capacity, 1, 0, 0)
	}
}
