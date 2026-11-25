// File templates. {{TOKEN}} placeholders are replaced by render.
package main

import "core:strings"

SCENE_CODE :: `// {{TITLE}}: scaffolded by tools/cubes. The demo spawn is a placeholder; replace it.
package {{NAME}}

import engine "../../engine"

State :: struct {
	world: engine.World,
}

{{NAME}}_scene :: proc() -> engine.Scene {
	return {
		name = "{{TITLE}}",
		create = {{NAME}}_create,
		tick = {{NAME}}_tick,
		destroy = {{NAME}}_destroy,
	}
}

{{NAME}}_create :: proc(demo: ^engine.Scene, ctx: ^engine.Context) -> bool {
	state := new(State)
	demo.state = state
	state.world = engine.world_create(&ctx.gfx)
	engine.camera_fly(ctx)
	// cubes:actors
	engine.spawn(&state.world, engine.Model{path = "static/models/rigged_cesiumman.glb"}, engine.Animator{clip = "clip_0"})
	return true
}

{{NAME}}_tick :: proc(demo: ^engine.Scene, ctx: ^engine.Context, delta_time: f32) {
	state := cast(^State)demo.state
	engine.world_update(&state.world, delta_time)
	engine.world_render(&state.world, ctx.blend)
}

{{NAME}}_destroy :: proc(demo: ^engine.Scene, ctx: ^engine.Context) {
	state := cast(^State)demo.state
	engine.world_destroy(&state.world)
	free(state)
}
`

SCENE_DATA :: `{
  "name": "{{TITLE}}"
}
`

ACTOR_CODE :: `// Per-actor convention: a struct that embeds engine.Actor and its Props, with self-only
// hooks. Props (Transform, Model, Health, ...) are fields of the struct; scenes only orchestrate.
package {{SCENE}}

import engine "../../engine"

{{TYPE}} :: struct {
	using actor:     engine.Actor,
	using transform: engine.Transform,
	// add Props as fields, e.g. using model: engine.Model, health: engine.Health
	ticks:           u32, // frames ticked
}

{{ACTOR}}_spawn :: proc(world: ^engine.World) -> ^{{TYPE}} {
	return engine.world_add_actor(world, {{TYPE}}{
		actor     = engine.actor_hooks({{TYPE}}, tick = {{ACTOR}}_tick, destroy = {{ACTOR}}_destroy),
		transform = engine.transform_create(),
	})
}

{{ACTOR}}_tick :: proc(self: ^{{TYPE}}, dt: f32) {
	self.ticks += 1
}

{{ACTOR}}_destroy :: proc(self: ^{{TYPE}}) {
}
`

// Replaces each {{KEY}} with its value; pairs are key, value, key, value, ...
render :: proc(template: string, pairs: ..string) -> string {
	out := template
	for i := 0; i < len(pairs); i += 2 {
		out, _ = strings.replace_all(out, strings.concatenate({"{{", pairs[i], "}}"}, context.temp_allocator), pairs[i + 1], context.temp_allocator)
	}
	return out
}
