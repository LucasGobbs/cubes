package gfx

// Resource scopes: every handle-based GPU resource created while a scope is
// open is destroyed by scope_end, in reverse creation order, unless it was
// destroyed manually first (manual destroy unregisters it).
//
// Rule for callers:
// - Handle resources (buffer, texture, sampler, pipeline, compute pipeline) and
//   everything built from them (Mesh, Font, Blur, Bloom, Skybox, Model GPU
//   parts) are freed by the scope. Manual *_destroy stays valid.
// - By-value structs (Model, Mesh, Skybox, Material) hold handles, not
//   pointers, so a scope can free them safely; their CPU-side parts (Model.skin,
//   Material arrays) are NOT freed by scope_end: call model_destroy /
//   material_destroy explicitly for those.
// - Renderer-owned targets rebuilt at runtime (MSAA, resize, transient pool) are
//   created paused so they belong to the renderer, never to a scene.
// - Resources created outside any scope are swept by gfx.destroy as before.

Resource_Kind :: enum u8 {
	Buffer,
	Texture,
	Sampler,
	Pipeline,
	Compute_Pipeline,
}

Scope_Entry :: struct {
	kind:   Resource_Kind,
	handle: Resource_Handle,
}

scope_begin :: proc(gfx_ctx: ^Device) {
	append(&gfx_ctx.scopes, [dynamic]Scope_Entry{})
}

scope_end :: proc(gfx_ctx: ^Device) {
	assert(len(gfx_ctx.scopes) > 0, "scope_end without scope_begin")
	entries := pop(&gfx_ctx.scopes)
	#reverse for entry in entries {
		switch entry.kind {
		case .Buffer:           buffer_destroy(gfx_ctx, Buffer_Handle(entry.handle))
		case .Texture:          texture_destroy(gfx_ctx, Texture_Handle(entry.handle))
		case .Sampler:          sampler_destroy(gfx_ctx, Sampler_Handle(entry.handle))
		case .Pipeline:         pipeline_destroy(gfx_ctx, Pipeline_Handle(entry.handle))
		case .Compute_Pipeline: compute_pipeline_destroy(gfx_ctx, Compute_Pipeline_Handle(entry.handle))
		}
	}
	delete(entries)
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
