package gfx

// Resource scopes: every GPU resource created while a scope is open is destroyed
// by scope_end, in reverse creation order, unless it was destroyed manually first
// (manual destroy unregisters it). Draws are truncated first, then entries run.
//
// Ownership, one rule per kind:
// - Handles (buffer, texture, sampler, pipeline, compute pipeline): tracked
//   automatically by their *_create. Manual *_destroy stays valid.
// - Scope-owned objects (heap, freed by scope_end via scope_defer): material_create,
//   model_add, skybox_add, draw_create with Mesh_Data. Never free them yourself;
//   their pointers stay valid until scope_end.
// - Borrowed objects (by value, caller frees): mesh_create, material_make,
//   model_load, draw_make/draw_model. Pair them with their *_destroy.
// - Draws from draw_create/draw_make/draw_model live in gfx_ctx.draws; scope_end
//   truncates the ones added inside the scope.
// - Renderer-owned targets rebuilt at runtime (MSAA, resize, transient pool) and
//   device caches (builtin pipelines, sampler presets) are created paused, so they
//   belong to the renderer or device, never to a scene.
// - Resources created outside any scope are swept by gfx.destroy.

Resource_Kind :: enum u8 {
	Buffer,
	Texture,
	Sampler,
	Pipeline,
	Compute_Pipeline,
	Custom,
}

Scope_Destroy_Proc :: proc(gfx_ctx: ^Device, user: rawptr)

Scope_Entry :: struct {
	kind:    Resource_Kind,
	handle:  Resource_Handle,
	destroy: Scope_Destroy_Proc, // Custom only
	user:    rawptr, // Custom only
}

scope_begin :: proc(gfx_ctx: ^Device) {
	append(&gfx_ctx.scopes, [dynamic]Scope_Entry{})
	append(&gfx_ctx.scope_draw_marks, len(gfx_ctx.draws))
}

scope_end :: proc(gfx_ctx: ^Device) {
	assert(len(gfx_ctx.scopes) > 0, "scope_end without scope_begin")
	resize(&gfx_ctx.draws, pop(&gfx_ctx.scope_draw_marks))
	entries := pop(&gfx_ctx.scopes)
	#reverse for entry in entries do scope_run(gfx_ctx, entry)
	delete(entries)
}

// Runs custom destroyer `destroy(gfx_ctx, user)` in the current scope's reverse
// order with its resources. Outside any scope it runs at gfx.destroy.
scope_defer :: proc(gfx_ctx: ^Device, destroy: Scope_Destroy_Proc, user: rawptr) {
	entry := Scope_Entry{kind = .Custom, destroy = destroy, user = user}
	if len(gfx_ctx.scopes) == 0 {
		append(&gfx_ctx.unscoped_entries, entry)
		return
	}
	append(&gfx_ctx.scopes[len(gfx_ctx.scopes) - 1], entry)
}

// Called by every *_create. No-op outside a scope or while paused.
scope_track :: proc(gfx_ctx: ^Device, kind: Resource_Kind, handle: Resource_Handle) {
	if len(gfx_ctx.scopes) == 0 || gfx_ctx.scope_paused > 0 do return
	append(&gfx_ctx.scopes[len(gfx_ctx.scopes) - 1], Scope_Entry{kind = kind, handle = handle})
}

// Called by every *_destroy after its validity check. Searches all open scopes.
scope_untrack :: proc(gfx_ctx: ^Device, kind: Resource_Kind, handle: Resource_Handle) {
	for &scope in gfx_ctx.scopes {
		for entry, index in scope {
			if entry.kind == kind && entry.handle == handle {
				ordered_remove(&scope, index)
				return
			}
		}
	}
}

@(private)
scope_run :: proc(gfx_ctx: ^Device, entry: Scope_Entry) {
	switch entry.kind {
	case .Buffer:           buffer_destroy(gfx_ctx, Buffer_Handle(entry.handle))
	case .Texture:          texture_destroy(gfx_ctx, Texture_Handle(entry.handle))
	case .Sampler:          sampler_destroy(gfx_ctx, Sampler_Handle(entry.handle))
	case .Pipeline:         pipeline_destroy(gfx_ctx, Pipeline_Handle(entry.handle))
	case .Compute_Pipeline: compute_pipeline_destroy(gfx_ctx, Compute_Pipeline_Handle(entry.handle))
	case .Custom:           entry.destroy(gfx_ctx, entry.user)
	}
}
