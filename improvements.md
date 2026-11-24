# Actor/Props API: gfx-free scenes, no "entity" word, extensible Props

## Context
Scenes today touch `gfx.*` directly (benchmark, boat, skinned, forest_*) and the ECS-like layer in `src/engine/world.odin` uses the words Entity/Component, which the user does not want (confused with ECS). Goal: (1) rename Entity→Actor, Component→Props everywhere (code, JSON, docs); (2) `World` becomes the high-level API: Actors are spawned with Props (mesh/model, collider, camera, environment...), users can register their own Prop types; (3) scenes benchmark, boat, skinned, physics, game, hello_engine use no `gfx.*` (raw gfx stays available as the performance path: forest_naive, forest_instanced, sea package, which only get the word rename).

Decisions already made with the user: extension by per-type registry (replaces the closed `Component` union); `World` owns a lazily created `phys.World` and drives Collider Props; migrate benchmark/boat/skinned too; JSON key `"entities"` becomes `"actors"` (clean cutover, no alias).

Found in code (read this session):
- `world.odin`: `Component :: union{Transform, Model, Animator, Camera, Camera_2D, Sprite, Sprite_Anim, Health, Name, Particle_Emitter}`; `Slot{generation, alive, born, components:[dynamic]Component, draw: gfx.Draw, playback, type, state, emitter}`; `slot_resolve` builds the Model draw / Animator / emitter after every change; `world_extract` submits only `slot.draw` (world scenes do not render `gfx_ctx.draws`, so no skybox/HUD exist there today); `world_draw_sprites` only runs when a `Camera_2D` exists.
- `asset_model` (assets.odin:26) already loads static glTF with the instanced pipeline, so Model actors batch like `model_add{kind=.Textured_Instanced}`.
- `physics.odin`: `body_box/body_sphere` (dynamic, centred at pos), `body_ground` (static, top face at y), `Tracked`, `track`, `tracked_snapshot`, `tracked_blend`. No body-destroy helper.
- `Renderer` fields scenes set: `fog [4]f32` (linear rgb + view distance), `light_direction`, `shadow_enabled`; `gfx.set_present_mode(gfx_ctx, .IMMEDIATE)`; `renderer.draw_calls`.
- `skybox_draw` and `skybox_destroy` in `gfx/skybox.odin` are `@(private="file")`; `skybox_create` is public.
- `host.odin` `app_tick` calls `world_update` then `world_render` (run_app).

## Approach
Order matters: step 1 first (pure rename, tree compiles), then 2, 3, 4 sequential in `world.odin` (same file), step 5 scene migrations are independent of each other and can run in parallel after 4.

### 0. Baseline
Before any edit: `make default-shaders shaders && odin build src -out:/tmp/cubes_base && /tmp/cubes_base benchmark --bench 5` twice; record `fps avg`, `draw calls`, `instances` lines. Step 5 compares against them.

### 1. Rename Entity→Actor, Component→Props (clean cutover, no aliases)
Exact renames, all callers in `src/`, `examples/`, tests:

| old | new |
|---|---|
| `Entity_Id` | `Actor_Id` |
| `Entity_Type`, `Entity_Type_Info`, private `entity_type_info` | `Actor_Type`, `Actor_Type_Info`, `actor_type_info` |
| `entity_get_component(world,id,T)` | `actor_props(world,id,T)` |
| `entity_add_component` | `actor_add_props` |
| `entity_remove_component` | `actor_remove_props` |
| `entity_transform`, `entity_set_transform` | `actor_transform`, `actor_set_transform` |
| `world_destroy_entity`, `world_entities` | `world_destroy_actor`, `world_actors` |
| `Entity_Def`, `Scene_Def.entities` (read the field in `scene_def.odin` first), JSON key `"entities"` | `Actor_Def`, `actors`, `"actors"` |
| private `entity_key`, `entity_components`, `entity_to_def`, `sync_entity` | `actor_key`, `actor_props_list`, `actor_to_def`, `sync_actor` |
| `Slot.components`, `Component` (union) | not renamed: the word "Component" is kept in step 1 only as the old union and `Slot.components` field; step 2 deletes both |
| `forest_naive` `grass_entity` | `grass_draw` |

- Also update every `scene.json` under `src/scenes/*/` and any JSON inside `*_test.odin` fixtures: `grep -rn '"entities"' src examples`.
- Replace the word in comments, docs and shader comments: files from `grep -rIli entity src docs README.md examples` (exclude `third_party/`, `*.dSYM`). In prose use "actor" when it means a world object, "resource"/"object" when it means a GPU object. `git mv docs/entity-map.md docs/resource-map.md` and fix links (`grep -rn "entity-map" docs README.md`).
- Gate: `grep -rIni entity src docs README.md examples` prints nothing (this also catches `Entity_Id` leftovers); `odin build src -out:/tmp/cubes_v` and `make test-engine` pass.

### 2. Props registry replaces the `Component` union (`src/engine/world.odin`)
No equivalent exists; follows the `register_type` pattern (type-erased procs via `transmute`, same ABI trick).

```odin
Prop_Info :: struct {
	size, align: int,
	added:   proc(world: ^World, id: Actor_Id, data: rawptr), // after the prop is stored (spawn: after ALL props of the spawn are stored; actor_add_props: right after)
	removed: proc(world: ^World, id: Actor_Id, data: rawptr), // before the prop is replaced or freed
}
Prop_Block :: struct { type: typeid, data: rawptr } // heap block, pointer stable until removed (replace overwrites in place)

register_props :: proc(world: ^World, $T: typeid,
	added: proc(world: ^World, id: Actor_Id, self: ^T) = nil,
	removed: proc(world: ^World, id: Actor_Id, self: ^T) = nil)
```
- `World` gets `props: map[typeid]Prop_Info`; `world_create` does `make` and registers every builtin Prop (list below) through `register_props`, so custom and builtin Props share one path. `world_destroy` deletes the map. A zero `World{}` has no registry: any test building `World{}` must use `world_create(nil)` (grep `World{` in `*_test.odin`).
- `Slot.components` becomes `props: [dynamic]Prop_Block`. Delete the `Component` union and `free_component`, `set_component`, `slot_component`'s union logic; `slot_component(slot, T)` becomes a linear search of `slot.props` by `typeid_of(T)` returning `^T` (nil if absent).
- Signatures (variadic `any` instead of the union, so user types work):
  - `spawn :: proc(world: ^World, props: ..any) -> Actor_Id`
  - `spawn_typed :: proc(world: ^World, type: Actor_Type, init: $T, props: ..any) -> (Actor_Id, ^T)`
  - `actor_add_props :: proc(world: ^World, id: Actor_Id, props: any)`
  - `actor_remove_props :: proc(world: ^World, id: Actor_Id, $T: typeid)` (assert `T != Transform` as today)
  - `actor_props :: proc(world: ^World, id: Actor_Id, $T: typeid) -> ^T`
- Storing a value `v: any`: look up `world.props[v.id]`; if missing `assert(false, "engine: props type not registered; call register_props")`; if `type_info_of(v.id).size != info.size` assert; if a block of that type exists call `removed` then `mem.copy` over it, else `mem.alloc` + copy + append. `spawn` always ensures a `Transform` (default `Transform{}` when none given). `sync_transform(slot)` still runs after any store (Transform is engine-known).
- `slot_resolve` is deleted; its three jobs move to builtin hooks:
  - `Transform.added`: normalize in place (zero scale→1, zero quaternion→identity; today's `normalize_transform`).
  - `Name.added`: `data.value = strings.clone(data.value)`; `Name.removed`: `delete(data.value)`.
  - `Model.added`: today's model branch of `slot_resolve` (asset_model, draw_make, cull, playback), then `apply_animator(slot)`; `Model.removed`: `remove_renderable(slot)`.
  - `Animator.added`: `apply_animator(slot)` (today's animator part of `slot_resolve`; no-op while `slot.draw.mesh == nil`, so spawn order Animator-before-Model works because `Model.added` re-applies it).
  - `Particle_Emitter.added`: today's emitter branch (position from the actor's Transform); `Particle_Emitter.removed`: `remove_emitter`.
  - Camera, Camera_2D, Sprite, Sprite_Anim, Health: registered with nil hooks (data read by world systems).
- `destroy_slot` calls each prop's `removed` hook (reverse order) then frees every block; keep today's ordering (actor type destroy proc first, then props).
- Hot reload `scene_apply.odin`: keep the typed per-builtin `sync_kind` (value equality needs string contents, which raw memory compare would break). Rewrite it to take `$T` and use `actor_props`/`actor_add_props`/`actor_remove_props`; `want` becomes a list of `any` built by `actor_props_list` (replacing `[]Component`), with `find_prop(list, T)` doing `any` → `T` by `v.id == T`. Props of types not in the file (custom/Collider) are left untouched.
- Public docs: header comment of `world.odin` rewritten to the Actor/Props recipe including a custom Prop example (`Hit_Box` with `added` hook).

### 3. Collider Prop and World-owned physics (`world.odin`, `physics/physics.odin`)
- `physics.odin`: add `body_static :: proc(w: World, pos, half: b3.Vec3) -> b3.BodyId` (static box centred at pos; same code as `body_ground` without the y shift) and `body_destroy :: proc(id: b3.BodyId)` calling `b3.DestroyBody(id)` (unverified — confirm the symbol name in `$(odin root)/vendor/box3d`).
- New Props in `world.odin`:
```odin
Box :: struct { half: Vec3 }
Sphere :: struct { radius: f32 }
Collider_Shape :: union { Box, Sphere }
Body_Kind :: enum { Dynamic, Static } // zero = Dynamic
Collider :: struct { shape: Collider_Shape, body: Body_Kind, density: f32 } // density 0 => 1
```
- `World` gets `physics: Maybe(phys.World)` (created on first Collider with default gravity `{0,-10,0}`; add `world.gravity: Vec3` read at that moment, set by `world_create(gfx_ctx, gravity := Vec3{0,-10,0})`) and `Slot.body: Maybe(phys.Tracked)`.
- `Collider.added`: at the actor's Transform position build the body: Static→`phys.body_static` (Box only; `assert` otherwise), Dynamic Box→`phys.body_box`, Dynamic Sphere→`phys.body_sphere`; `slot.body = phys.track(id)`. Initial rotation from Transform is ignored (`shortcut:` comment, upgrade when a scene needs rotated bodies). `Collider.removed`: `phys.body_destroy`, `slot.body = nil`. A world without a Device is allowed (tests).
- `world_update`: after the actor tick loop and before `sync_transform`, `phys.step(world, dt)` when `world.physics` is set, then for each slot with `body`: `tracked_snapshot`, and write the Transform position/rotation from the tracked `curr` pose for Dynamic bodies (scale untouched).
- `world_render :: proc(world: ^World, blend := f32(1))`: before extract, for every slot with a Dynamic `body`, set Transform from `phys.tracked_blend(tracked, blend)` and call `sync_transform`. Callers: `host.odin app_tick` passes `ctx.blend`; scenes that step in `fixed_tick` pass `ctx.blend`.
- `world_destroy`: `phys.destroy` the world after actors are destroyed.

### 4. Graphics abstraction Props and helpers (`world.odin`, `context.odin`, `gfx/skybox.odin`)
Each item exists because a migrated scene calls `gfx.*` for it today.
- `Environment :: struct { skybox: string, fog: Maybe(Fog), shadows: Maybe(bool), sun_direction: Maybe(Vec3), uncapped: bool }`, `Fog :: struct { color: [3]f32 /* sRGB */, distance: f32 }`. First live actor with it drives the renderer, applied each `world_update` (like Camera): `renderer.fog = {linear.rgb, distance}` via `gfx.color_srgb_to_linear` (or `{}` when nil), `shadow_enabled`, `light_direction` (normalized), `gfx.set_present_mode(.IMMEDIATE)` when `uncapped`. Skybox: when `skybox` path changes, create `world.sky: Maybe(gfx.Skybox)` with `gfx.skybox_create` and replace the old one; `world_extract` appends a pointer to a `Draw` built by `gfx.skybox_draw` (remove `@(private="file")` from `skybox_draw` and `skybox_destroy` in `gfx/skybox.odin`). `world_destroy` destroys it. Scenes toggle fog by mutating `actor_props(world, id, Environment).fog`.
- `Raw_Draw :: struct { mesh: gfx.Mesh_Data, material: ^gfx.Material }`: custom-shader escape hatch (sea). `added`: build an owned `^gfx.Mesh` (`mesh_create`/`mesh_create_unindexed`, same branch as `draw_create`'s `Mesh_Data` case), `slot.draw = gfx.draw_make(mesh, material)`, `slot.owned_mesh = mesh` (new Slot field); `removed`: `remove_renderable` also `gfx.mesh_destroy` + `free` the owned mesh.
- `actor_emitter :: proc(world: ^World, id: Actor_Id) -> ^particles.Emitter` returns `particles.emitter_get(world.particles, handle)` or nil; scenes mutate direction and burst through it.
- HUD text: `world_text :: proc(world: ^World, text: string, position: [2]f32, color := [4]f32{1,1,1,1})`: color is sRGB (converted with `gfx.color_srgb_to_linear`), position in window px, y down. Appends a `{text cloned to temp allocator, position, color}` to `world.texts` (cleared after render). `world.hud: Maybe(Hud)` with `Hud{batch: gfx.Batch, font: gfx.Font}` created lazily on first text (font `static/fonts/andale-mono.ttf`, constant `HUD_FONT_PATH`, `gfx.batch_register`), destroyed in `world_destroy`. `world_render` draws it, as a batch separate from the sprite batch, before the frame (same place as `world_draw_sprites`), with `gfx.Camera2D{position = window_size/2}` exactly like `benchmark_tick` does today. Runs whenever `len(world.texts) > 0`, independent of Camera_2D.
- `draw_call_count :: proc(ctx: ^Context) -> int` in `context.odin` returns `ctx.gfx.renderer.draw_calls`.

### 5. Migrate scenes (parallel, one scene per worker)
Pattern for all: scene state holds `world: engine.World`; `create` does `engine.world_create(&ctx.gfx)`, spawns; `tick` mutates props then `world_update` + `world_render(&world, ctx.blend)`; `destroy` `world_destroy`. Camera stays `engine.camera_fly(ctx)` (host controller). Reference: `src/scenes/physics/scene.odin` today and `examples/hello_engine/main.odin`.
- `src/scenes/skinned/scene.odin`: spawn `Model{path=SKINNED_MODEL_PATH}`, `Animator{clip=SKINNED_CLIP}`; delete loader/gfx imports and `Skinned_State` model/playback.
- `src/scenes/physics/scene.odin`: drop `phys` import and `Physics_Ball.track`; spawn ground `Collider{shape=Box{{20,0.5,20}}, body=.Static}` at `Transform{position={0,-0.5,0}}`; each ball `Model`, `Collider{shape=Sphere{BALL_RADIUS}}`, `Transform{position, scale}`; `fixed_tick` = `world_update`; `tick` = `world_render(&world, ctx.blend)`.
- `src/scenes/game/*`: only the step-1 rename plus `spawn`/`actor_props` call updates (already uses World; its 3 `gfx.` refs: if any is a plain type like `gfx.Vec3`, switch to `engine.Vec3`).
- `examples/hello_engine/main.odin`: step-1 rename only.
- `src/scenes/boat/scene.odin`: actors: sea via a new helper `sea.add(world, ctx, &state.sea_state) -> engine.Actor_Id` in `src/scenes/sea/` (creates pipeline/material, spawns `Raw_Draw`, keeps the material in `sea.State` for destroy; sea package keeps its gfx use: custom-shader path); `Environment{skybox=default.SKYBOX_PATH, fog = Fog{{0.671,0.757,0.949}, FOG_VIEW_DISTANCE}}`; boat = `Model{path=BOAT_PATH}`; each particle emitter = actor with `Particle_Emitter{...same desc}` and `Transform`; per-tick direction/burst through `actor_emitter`, positions through `actor_transform(...).position`. Remove `particles.system_create/destroy`, `gfx.draw_move`, `gfx.render`.
- `src/scenes/benchmark/scene.odin`: boats/dragons are `Model` actors; `Boat_Slot.draw int`→`actor: engine.Actor_Id`, tick writes through the pointer `engine.actor_transform(...)` (not `actor_add_props`, avoids hooks for ~thousands of actors per frame); `benchmark_populate` destroys the listed boat+dragon actors (keep `[dynamic]Actor_Id`) instead of `resize(&gfx_ctx.draws, ...)`; `Environment{skybox, fog, uncapped=true}`; V toggles `env.fog` nil/set; HUD through `engine.world_text` and `engine.draw_call_count(ctx)`; remove Font/Batch from state.
- Files with `gfx.`: `forest_naive`, `forest_instanced`, `sea` keep raw gfx (performance path); they only got the step-1 rename.
- Gate for migrated scenes: `grep -n "gfx" src/scenes/{skinned,physics,game,boat,benchmark}/*.odin` prints only the `sea.` helper calls and nothing importing `engine/gfx`.

### 6. Tests (`src/engine/*_test.odin`)
Update renamed ones (`world_test`, `registry_test`, `scene_apply_test`, `scene_data_test`, `gfx/animation_test`, `gfx/material_pipeline_test`). Add in `world_test.odin`:
- custom Prop: `Hit_Box{hp: int}` registered with `added` that increments a counter and `removed` that decrements; spawn → count 1; `actor_add_props` replace → removed then added (count stays 1); `actor_remove_props` and `world_destroy_actor` → 0; unregistered type asserts (skip if assert tests are not used in this repo).
- Collider (no Device): static ground `Box{{10,0.5,10}}` at y=-0.5 plus dynamic `Sphere{0.5}` at y=3; 120 × `world_update(dt=1/60)`: sphere Transform.y ends within [0.4, 0.6]; `world_render` is not called (needs Device).

## Critical files & anchors
- `src/engine/world.odin` — `Component`, `Slot`, `slot_resolve`, `spawn`, `world_update` (~:387), `world_extract` (~:422): central rewrite.
- `src/engine/scene_apply.odin` — `sync_kind`/`find_component` generic code rewritten to `any`.
- `src/engine/physics/physics.odin` — add `body_static`, `body_destroy` next to `body_ground`.
- `src/engine/gfx/skybox.odin` — make `skybox_draw`/`skybox_destroy` public.
- `src/scenes/benchmark/scene.odin` — largest migration; keep the bench numbers.

## Verification
All from repo root after `make default-shaders shaders`.
- After every step: `odin build src -out:/tmp/cubes_v` and `make test-engine`. The known `grass_chunk_budget` failure in `src/scenes/forest_naive` predates this work and is not a gate.
- Step 1: `grep -rIni entity src docs README.md examples` empty; `/tmp/cubes_v game --bench 2` and a data scene (`/tmp/cubes_v <scene with scene.json>`) still load (JSON `"actors"` read).
- Step 3: new Collider test passes; `/tmp/cubes_v physics` — 20 balls fall and rest on the ground, motion smooth (blend), no `gfx`/`phys` in the scene file.
- Step 4/5 skinned: `/tmp/cubes_v skinned` character animates.
- Step 5 boat: `/tmp/cubes_v boat` shows sea, skybox, fog, smoke/foam/rain/fireworks as before.
- Step 5 benchmark: `/tmp/cubes_v benchmark --bench 5` x2: `draw calls` and `instances` equal to the step 0 numbers (±0), `fps avg` not more than 10% below step 0's (noisy: compare the two runs' ranges). In window: HUD text visible, `=`/`-` change counts, `V` toggles fog.
- Step 5 extensibility smoke: temporary scene code (removed afterwards) registers `Spin :: struct{speed: f32}` with a `register_type` tick rotating its actor; actor spins on screen.

## Assumptions & contingencies
- Props equality for hot reload stays typed for builtins; JSON cannot express Collider/Environment/Raw_Draw/custom Props (only the existing flat fields). If the user wants JSON colliders later, add flat fields to `Actor_Def`.
- If `world_extract` needs the skybox in a different Render_Layer submit path (skybox draw not shown when submitted through `renderer_submit_draw_ptrs`), submit it through `gfx.renderer_submit(...)` as `draw_create` entries are submitted today (read `renderer_submit_draws` in `gfx/draw.odin`).
- If `b3.DestroyBody` does not exist, leak the body until `phys.destroy` and note a `shortcut:` comment.
- If benchmark fps drops >10% because `world_extract` rebuilds the draw pointer list for ~5000 actors each frame, cache the list in `World` and rebuild only when `spawn`/`destroy` marks it dirty.
