// Actor x Props world on top of gfx. Spawn actors with Props (builtin or your own);
// models, pipelines, skins, camera and post-process passes are resolved here.
//
// Recipe (examples/hello_engine/main.odin):
//   App :: struct { hero: engine.Actor_Id }
//   main :: proc() { app: App; engine.run_app(&app, start, update, title = "app") }
//   start :: proc(app: ^App, world: ^engine.World) {
//       engine.spawn(world,
//           engine.Camera{look_at = engine.Vec3{0, 0.8, 0}, bloom = engine.Bloom{}},
//           engine.Transform{position = {0, 1, 1.9}})
//       app.hero = engine.spawn(world,
//           engine.Model{path = "static/models/rigged_cesiumman.glb"},
//           engine.Animator{clip = "clip_0"})
//   }
//   update :: proc(app: ^App, world: ^engine.World, dt: f32) {
//       // edit any Transform here: engine.actor_props(world, app.hero, engine.Transform)
//   }
//
// Custom Prop: any plain struct, registered once per World. Hooks are optional:
// added runs after the Prop is stored (spawn: after all Props of the spawn are
// stored), removed runs before it is replaced or freed.
//   Hit_Box :: struct { hp: int }
//   hit_boxes: int // counted by the hooks below
//   hit_box_added :: proc(world: ^engine.World, id: engine.Actor_Id, self: ^Hit_Box) { hit_boxes += 1 }
//   hit_box_removed :: proc(world: ^engine.World, id: engine.Actor_Id, self: ^Hit_Box) { hit_boxes -= 1 }
//   // start:  engine.register_props(world, Hit_Box, hit_box_added, hit_box_removed)
//   // spawn:  engine.spawn(world, Hit_Box{hp = 3}, engine.Transform{position = {0, 1, 0}})
//   // read:   engine.actor_props(world, id, Hit_Box).hp
//   // remove: engine.actor_remove_props(world, id, Hit_Box)
//
// Per-actor logic (registry): a state struct plus create/tick/destroy procs.
//   Ship :: struct { target: engine.Actor_Type }
//   ship_create :: proc(world: ^engine.World, id: engine.Actor_Id, self: ^Ship) { /* actor_add_props */ }
//   ship_tick :: proc(world: ^engine.World, id: engine.Actor_Id, self: ^Ship, dt: f32) { /* ... */ }
//   // start:  ship := engine.register_type(world, Ship, ship_create, ship_tick, nil)
//   // spawn:  engine.spawn_typed(world, ship, Ship{target = player_type})
// Ticks run in slot order (spawn order, reused slots included), once per world_update.
// Actors spawned during world_update first tick on the next one.
// Lua behaviour: Script{path = "src/scenes/<scene>/x.lua"} runs the module's create and destroy
// around its Prop's lifetime, and tick / fixed_tick in world_update / world_fixed_update.
// A runtime error faults that actor's script only (logged once). script_call calls a
// named Lua function from Odin.
package engine

import "core:log"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:reflect"
import "core:slice"
import "core:strings"
import gfx "gfx"
import "jobs"
import particles "particles"
import phys "physics"

Vec3 :: gfx.Vec3

// Generation 0 is never a live slot, so the zero Actor_Id is always invalid.
Actor_Id :: struct {
	index, generation: u32,
}

// Handle from register_type. Zero is invalid; handles are 1-based indices into World.types.
Actor_Type :: distinct u32

// Procs are stored type-erased. The state is a heap block owned by the slot.
Actor_Type_Info :: struct {
	state_size, state_align: int,
	create:                  proc(world: ^World, id: Actor_Id, state: rawptr),
	tick:                    proc(world: ^World, id: Actor_Id, state: rawptr, dt: f32),
	fixed_tick:              proc(world: ^World, id: Actor_Id, state: rawptr, dt: f32),
	destroy:                 proc(world: ^World, id: Actor_Id, state: rawptr),
	contact:                 proc(world: ^World, id: Actor_Id, state: rawptr, other: Actor_Id),
}

Transform :: struct {
	position: Vec3,
	rotation: linalg.Quaternionf32,
	scale:    Vec3,
}

// path is borrowed: the string must outlive the actor.
Model :: struct {
	path: string,
}

// clip is the name of a clip in the model's skin. Needs a skinned Model.
Animator :: struct {
	clip: string,
}

// Zero fields mean defaults: threshold 0.8, intensity 0.6, radius 6.
Bloom :: struct {
	threshold, intensity: f32,
	radius:               i32,
}

// The first live actor with a Camera drives the renderer camera. Its position
// comes from its Transform; look_at (a world point) overrides the Transform rotation.
// fov_y 0 => gfx.CAMERA_FOV_Y. bloom and blur enable those post effects for the
// frame; blur is a radius in texels, 0 => 4.
Camera :: struct {
	fov_y:   f32,
	look_at: Maybe(Vec3),
	bloom:   Maybe(Bloom),
	blur:    Maybe(i32),
}

// The first live actor with an Environment drives the renderer on every world_update.
// skybox: equirectangular panorama path, "" = none; borrowed, the World keeps its own copy.
// fog nil = off; shadows nil = on; sun_direction nil = gfx.DEFAULT_LIGHT_DIRECTION.
// uncapped switches the present mode to IMMEDIATE (tearing allowed).
Environment :: struct {
	skybox:        string,
	fog:           Maybe(Fog),
	shadows:       Maybe(bool),
	sun_direction: Maybe(Vec3),
	uncapped:      bool,
	grade:         Maybe(Grade), // nil = no tonemap pass; exposure, contrast and saturation of the final image
}

// color is sRGB. Fog starts at 60% of distance and is full at distance.
Fog :: struct {
	color:    [3]f32,
	distance: f32,
}

// exposure in EV stops (2^EV); contrast and saturation: 1 = unchanged.
Grade :: struct {
	exposure:   f32,
	contrast:   f32,
	saturation: f32,
}

// A textured quad drawn by the World's 2D batch at its Transform (position.xy in
// world px, scale.xy multiplies the frame size, rotation about Z). texture is
// borrowed. grid {0,0} = whole image; otherwise frame indexes cells row-major.
Sprite :: struct {
	texture:        string,
	grid:           [2]i32,
	frame:          i32,
	color:          [4]f32, // {0,0,0,0} = white
	origin:         Maybe([2]f32), // nil = centre
	flip_x, flip_y: bool,
	layer:          i32, // draw order before position.z
}

// Advances the sprite frame: time in seconds, advanced by world_update.
Sprite_Anim :: struct {
	first, last: i32,
	fps:         f32,
	loop:        bool,
	time:        f32,
}

// Custom-shader escape hatch. The mesh is uploaded when the Prop is added, so the
// vertex slices need not outlive it; material is borrowed.
Raw_Draw :: struct {
	mesh:     gfx.Mesh_Data,
	material: ^gfx.Material,
}

// The first live actor with a Camera_2D drives the 2D view; its position comes
// from Transform.position.xy (world px).
Camera_2D :: struct {
	zoom:          f32, // 0 = 1
	viewport:      [2]f32, // logical resolution; {0,0} = window size
	integer_scale: bool,
}

// Plain data: game code reads and writes current through actor_props.
Health :: struct {
	current, max: f32,
}

// Box collider half extents, relative to the actor's position.
Box :: struct {
	half: Vec3,
}

Sphere :: struct {
	radius: f32,
}

Collider_Shape :: union {
	Box,
	Sphere,
}

// Dynamic bodies move their actor; Static bodies stay where the Transform put them. Zero = Dynamic.
Body_Kind :: enum {
	Dynamic,
	Static,
}

// Physics body at the actor's Transform position, owned by the World. density 0 => 1.
Collider :: struct {
	shape:   Collider_Shape,
	body:    Body_Kind,
	density: f32,
}

// Actor name: key for world_find_by_name and hot reload. The world clones value on set.
Name :: struct {
	value: string,
}

// Emitter spawned at the actor Transform position; needs a World with a Device.
Particle_Emitter :: particles.Emitter_Desc

// Type-erased hooks of one Prop type (see register_props).
Prop_Info :: struct {
	size, align: int,
	added:       proc(world: ^World, id: Actor_Id, data: rawptr), // after the Prop is stored
	removed:     proc(world: ^World, id: Actor_Id, data: rawptr), // before it is replaced or freed
}

// One Prop of an actor: heap block, stable until the Prop is removed.
Prop_Block :: struct {
	type: typeid,
	data: rawptr,
}

World :: struct {
	gfx_ctx:   ^gfx.Device, // nil is fine for worlds that only hold Transforms (tests)
	jobs:      ^jobs.Pool, // borrowed from the renderer; nil = serial
	props:     map[typeid]Prop_Info, // registered Prop types; see register_props
	slots:     [dynamic]Slot,
	free:      [dynamic]u32,
	types:     [dynamic]Actor_Type_Info,
	assets:    Assets,
	updating:  bool, // true while world_update ticks; spawns then wait one frame
	time:      f32, // scene clock in seconds: world_update adds dt; world_fixed_update does not
	bloom:     ^gfx.Bloom,
	blur:      ^gfx.Blur,
	tonemap:   ^gfx.Tonemap, // lazy like bloom: created on the first Environment with a grade
	particles: ^particles.System, // lazy like bloom/blur: created on the first Particle_Emitter
	batch:     Maybe(gfx.Batch),
	camera_2d: gfx.Camera2D,
	gravity:   Vec3, // read when the physics world is created on the first Collider
	physics:   Maybe(phys.World), // lazy like particles: created on the first Collider
	contact_actors: map[phys.Body]Actor_Id, // body -> actor owning its Collider; lazy like physics, freed in world_destroy
	texts:     [dynamic]Hud_Text, // queued by world_text; world_render draws and clears them
	hud:       Maybe(Hud), // lazy like batch: created on the first world_text
	sky:       Maybe(gfx.Skybox), // lazy: follows Environment.skybox
	sky_path:  string, // owned copy of the path sky was built from
	uncapped:  bool, // IMMEDIATE present mode, applied by Environment
	scripts:   ^Script_Host, // lazy like particles: created on the first Script
}

// Font and batch of world_text; created on the first text.
Hud :: struct {
	batch: gfx.Batch,
	font:  gfx.Font,
}

// Queued by world_text. position in window px, y down; color is linear rgba.
Hud_Text :: struct {
	text:     string,
	position: [2]f32,
	color:    [4]f32,
}

HUD_FONT_PATH :: "static/fonts/andale-mono.ttf"

Slot :: struct {
	generation: u32,
	alive:      bool,
	born:       bool, // spawned during the current world_update: skip its tick
	props:      [dynamic]Prop_Block,
	draw:       gfx.Draw,
	owned_mesh: ^gfx.Mesh, // Raw_Draw's mesh; freed when the Prop is removed
	playback:   Maybe(gfx.Playback), // skinned Models only
	type:       Actor_Type, // 0 when the actor has no registered type
	state:      rawptr,
	emitter:    Maybe(particles.Emitter_Handle), // this actor's emitter; nil when none
	body:       Maybe(phys.Tracked), // this actor's Collider body; nil when none
}

// Use world_create; a zero World has no Prop registry or asset cache.
world_create :: proc(gfx_ctx: ^gfx.Device, gravity := Vec3{0, -10, 0}) -> World {
	world := World{gfx_ctx = gfx_ctx, jobs = gfx_ctx.renderer.jobs if gfx_ctx != nil else nil, props = make(map[typeid]Prop_Info), assets = {models = make(map[string]^Model_Asset)}, gravity = gravity}
	register_props(&world, Transform, transform_added)
	register_props(&world, Name, name_added, name_removed)
	register_props(&world, Model, model_added, model_removed)
	register_props(&world, Animator, animator_added)
	register_props(&world, Particle_Emitter, emitter_added, emitter_removed)
	register_props(&world, Camera)
	register_props(&world, Camera_2D)
	register_props(&world, Sprite)
	register_props(&world, Sprite_Anim)
	register_props(&world, Health)
	register_props(&world, Collider, collider_added, collider_removed)
	register_props(&world, Environment)
	register_props(&world, Raw_Draw, raw_draw_added, raw_draw_removed)
	register_props(&world, Script, script_added, script_removed)
	return world
}

// Registers a per-actor state type. create runs after spawn, tick once per
// world_update, destroy before the actor's Props are freed. fixed_tick runs once per
// world_fixed_update and never from world_update. Any proc may be nil.
register_type :: proc(
	world: ^World,
	$T: typeid,
	create: proc(world: ^World, id: Actor_Id, self: ^T),
	tick: proc(world: ^World, id: Actor_Id, self: ^T, dt: f32),
	destroy: proc(world: ^World, id: Actor_Id, self: ^T),
	fixed_tick: proc(world: ^World, id: Actor_Id, self: ^T, dt: f32) = nil,
	contact: proc(world: ^World, id: Actor_Id, self: ^T, other: Actor_Id) = nil,
) -> Actor_Type {
	info := Actor_Type_Info{state_size = size_of(T), state_align = align_of(T)}
	// Same ABI trick as run: only the pointer parameter type differs.
	if create != nil do info.create = transmute(proc(^World, Actor_Id, rawptr))create
	if tick != nil do info.tick = transmute(proc(^World, Actor_Id, rawptr, f32))tick
	if fixed_tick != nil do info.fixed_tick = transmute(proc(^World, Actor_Id, rawptr, f32))fixed_tick
	if contact != nil do info.contact = transmute(proc(^World, Actor_Id, rawptr, Actor_Id))contact
	if destroy != nil do info.destroy = transmute(proc(^World, Actor_Id, rawptr))destroy
	append(&world.types, info)
	return Actor_Type(len(world.types))
}

// Registers a Prop type for this World. spawn, actor_add_props and hot reload accept
// only registered types; world_create registers the builtins. added/removed may be nil.
register_props :: proc(
	world: ^World,
	$T: typeid,
	added: proc(world: ^World, id: Actor_Id, self: ^T) = nil,
	removed: proc(world: ^World, id: Actor_Id, self: ^T) = nil,
) {
	info := Prop_Info{size = size_of(T), align = align_of(T)}
	// Same ABI trick as register_type: only the pointer parameter type differs.
	if added != nil do info.added = transmute(proc(^World, Actor_Id, rawptr))added
	if removed != nil do info.removed = transmute(proc(^World, Actor_Id, rawptr))removed
	world.props[typeid_of(T)] = info
}

// Copies init into a new state block, spawns the Props, then runs create.
// Props of one type replace the earlier one; Transform is always present.
spawn_typed :: proc(world: ^World, type: Actor_Type, init: $T, props: ..any) -> (Actor_Id, ^T) {
	info := actor_type_info(world, type, T)
	state, err := mem.alloc(info.state_size, info.state_align)
	assert(err == nil, "engine: out of memory for actor state")
	(^T)(state)^ = init
	id := spawn(world, ..props)
	slot := &world.slots[id.index]
	slot.type = type
	slot.state = state
	if info.create != nil do info.create(world, id, state)
	return id, (^T)(state)
}

// Props are plain values of registered types. Props of one type replace the
// earlier one. Every actor gets a Transform (a default one when none is given).
spawn :: proc(world: ^World, props: ..any) -> Actor_Id {
	index := claim_slot(world)
	slot := &world.slots[index]
	id := Actor_Id{index, slot.generation}
	// Transform is stored first: the other added hooks read the normalized transform.
	transform: any = Transform{}
	for prop in props do if prop.id == typeid_of(Transform) do transform = prop
	store_prop(world, id, transform, false)
	for prop in props do if prop.id != typeid_of(Transform) do store_prop(world, id, prop, false)
	// Added hooks can add Props (a Script's create sets a Name) and spawn more actors: those
	// already ran their own added hook, so visit only the blocks that existed before the loop.
	count := len(world.slots[index].props)
	for i in 0 ..< count {
		props := world.slots[index].props
		if i >= len(props) do break
		run_added(world, id, props[i].type, props[i].data)
	}
	sync_transform(&world.slots[index])
	return id
}

// Spawns a 3D camera at position looking at look_at; fov_y 0 => gfx.CAMERA_FOV_Y.
// For bloom or blur, spawn a Camera literal instead.
spawn_camera :: proc(world: ^World, position: Vec3, look_at := Vec3{}, fov_y: f32 = 0) -> Actor_Id {
	return spawn(world, Camera{fov_y = fov_y, look_at = look_at}, Transform{position = position})
}

world_valid :: proc(world: ^World, id: Actor_Id) -> bool {
	if int(id.index) >= len(world.slots) do return false
	slot := &world.slots[id.index]
	return slot.alive && slot.generation == id.generation
}

// Pointer to one of the actor's Props; stable until that Prop is removed.
actor_props :: proc(world: ^World, id: Actor_Id, $T: typeid) -> ^T {
	if !world_valid(world, id) do return nil
	return slot_component(&world.slots[id.index], T)
}

// First live actor whose Name equals name. Returns the zero Actor_Id and false if none.
world_find_by_name :: proc(world: ^World, name: string) -> (Actor_Id, bool) {
	for &slot, index in world.slots {
		if !slot.alive do continue
		if prop := slot_component(&slot, Name); prop != nil && prop.value == name {
			return Actor_Id{u32(index), slot.generation}, true
		}
	}
	return {}, false
}

// Live actors in slot order (temp allocator).
world_actors :: proc(world: ^World) -> []Actor_Id {
	list := make([dynamic]Actor_Id, context.temp_allocator)
	for &slot, index in world.slots do if slot.alive do append(&list, Actor_Id{u32(index), slot.generation})
	return list[:]
}

// State of an actor spawned with spawn_typed. Nil for invalid ids.
world_get_state :: proc(world: ^World, id: Actor_Id, $T: typeid) -> ^T {
	if !world_valid(world, id) do return nil
	slot := &world.slots[id.index]
	if _, ok := slot_type(world, slot); !ok do return nil
	_ = actor_type_info(world, slot.type, T)
	return (^T)(slot.state)
}

// First live actor of type, in slot order. Returns the zero Actor_Id and nil if none.
world_find_state :: proc(world: ^World, type: Actor_Type, $T: typeid) -> (Actor_Id, ^T) {
	_ = actor_type_info(world, type, T)
	for &slot, index in world.slots {
		if slot.alive && slot.type == type do return Actor_Id{u32(index), slot.generation}, (^T)(slot.state)
	}
	return {}, nil
}

// Live actors of type.
world_count :: proc(world: ^World, type: Actor_Type) -> int {
	count := 0
	for &slot in world.slots do if slot.alive && slot.type == type do count += 1
	return count
}

// Adds a Prop, replacing the actor's Prop of the same type. The old Prop's removed
// hook runs first; the new one's added hook runs after the store.
actor_add_props :: proc(world: ^World, id: Actor_Id, prop: any) {
	assert(world_valid(world, id), "engine: actor_add_props on invalid actor")
	data := store_prop(world, id, prop, true)
	run_added(world, id, prop.id, data)
	sync_transform(&world.slots[id.index])
}

// Removes the actor's Prop of type T; Transform cannot be removed. Removed hook runs first.
actor_remove_props :: proc(world: ^World, id: Actor_Id, $T: typeid) {
	assert(T != Transform, "engine: Transform cannot be removed")
	if !world_valid(world, id) do return
	slot := &world.slots[id.index]
	for block, index in slot.props {
		if block.type != typeid_of(T) do continue
		run_removed(world, id, block.type, block.data)
		free(block.data)
		ordered_remove(&slot.props, index)
		return
	}
}

// Transform of a live actor, nil if the id is invalid. Every actor has one from spawn.
actor_transform :: proc(world: ^World, id: Actor_Id) -> ^Transform {
	return actor_props(world, id, Transform)
}

// Replaces the actor's Transform. Zero rotation or scale mean defaults, as in spawn.
actor_set_transform :: proc(world: ^World, id: Actor_Id, position := Vec3{}, rotation := linalg.QUATERNIONF32_IDENTITY, scale := Vec3{1, 1, 1}) {
	actor_add_props(world, id, Transform{position = position, rotation = rotation, scale = scale})
}

// The actor's Particle_Emitter, nil when it has none. Mutate direction or burst through it.
actor_emitter :: proc(world: ^World, id: Actor_Id) -> ^particles.Emitter {
	if !world_valid(world, id) do return nil
	handle, ok := world.slots[id.index].emitter.?
	if !ok || world.particles == nil do return nil
	return particles.emitter_get(world.particles, handle)
}

// Runs the destroy proc while Props are still alive, then the removed hooks and frees.
// No-op for invalid ids, so a stale id can be destroyed twice safely.
world_destroy_actor :: proc(world: ^World, id: Actor_Id) {
	if !world_valid(world, id) do return
	if info, ok := slot_type(world, &world.slots[id.index]); ok && info.destroy != nil {
		info.destroy(world, id, world.slots[id.index].state)
		// The destroy proc may have destroyed other actors, or this one.
		if !world_valid(world, id) do return
	}
	destroy_slot(world, id)
	append(&world.free, id.index)
}

// Destroys every live actor of type (their destroy procs run).
world_destroy_type :: proc(world: ^World, type: Actor_Type) {
	for index := 0; index < len(world.slots); index += 1 {
		slot := world.slots[index]
		if slot.alive && slot.type == type do world_destroy_actor(world, Actor_Id{u32(index), slot.generation})
	}
}

// Frees every actor, cached asset and effect. Clears the Post passes, fog, sun and
// present mode this world may have set on the renderer. Compute pipelines are freed with the Device.
world_destroy :: proc(world: ^World) {
	if world.gfx_ctx != nil {
		if batch, ok := &world.batch.?; ok do gfx.batch_destroy(world.gfx_ctx, batch)
		if hud, ok := &world.hud.?; ok {
			gfx.batch_destroy(world.gfx_ctx, &hud.batch)
			gfx.font_destroy(world.gfx_ctx, &hud.font)
		}
		if sky, ok := &world.sky.?; ok do gfx.skybox_destroy(world.gfx_ctx, sky)
		gfx.renderer_clear_passes(&world.gfx_ctx.renderer, .Post)
		gfx.renderer_clear_passes(&world.gfx_ctx.renderer, .Final)
		world.gfx_ctx.renderer.clear_color = gfx.DEFAULT_CLEAR_COLOR
		world.gfx_ctx.renderer.fog = {}
		world.gfx_ctx.renderer.shadow_enabled = true
		gfx.renderer_update_light(&world.gfx_ctx.renderer, gfx.DEFAULT_LIGHT_DIRECTION)
		if world.uncapped do gfx.set_present_mode(world.gfx_ctx, .VSYNC)
	}
	for index := 0; index < len(world.slots); index += 1 {
		slot := world.slots[index]
		if slot.alive do world_destroy_actor(world, Actor_Id{u32(index), slot.generation})
	}
	if world.scripts != nil do script_host_destroy(world.scripts)
	if world_phys, ok := world.physics.?; ok do phys.destroy(world_phys)
	if world.contact_actors != nil do delete(world.contact_actors)
	delete(world.slots)
	delete(world.free)
	if len(world.sky_path) > 0 do delete(world.sky_path)
	delete(world.texts)
	delete(world.types)
	delete(world.props)
	assets_destroy(world)
	free(world.bloom)
	free(world.blur)
	free(world.tonemap)
	if world.particles != nil {
		particles.system_destroy(world.particles)
		world.particles = nil
	}
	world^ = {}
}

// Ticks each registered actor once, then copies each Transform into its actor,
// ticks animations, and applies the first Camera to the renderer. Ticks run in slot
// order, so the player is ticked before enemies when it is spawned first.
world_update :: proc(world: ^World, dt: f32) {
	world.time += dt
	script_host_poll_reload(world)
	world.updating = true
	// Index loop: a tick may spawn (reallocating slots) or destroy, so re-read each step.
	for index := 0; index < len(world.slots); index += 1 {
		slot := &world.slots[index]
		if !slot.alive || slot.born do continue
		info, ok := slot_type(world, slot)
		if !ok || info.tick == nil do continue
		info.tick(world, Actor_Id{u32(index), slot.generation}, slot.state, dt)
	}
	script_update(world, dt, .Tick)
	world.updating = false
	if world_phys, ok := world.physics.?; ok {
		phys.step(world_phys, dt)
		// Snapshot every body; Dynamic ones drive their Transform from the new pose.
		for &slot in world.slots {
			if body, ok := &slot.body.?; ok do phys.tracked_snapshot(body)
			if body, ok := dynamic_body(&slot); ok {
				transform := slot_component(&slot, Transform)
				transform.position = body.curr.pos
				transform.rotation = body.curr.rot
			}
		}
		world.updating = true
		dispatch_contacts(world, phys.contact_begin_events(world_phys))
		world.updating = false
	}
	playbacks := make([dynamic]^gfx.Playback, 0, 0, context.temp_allocator)
	for &slot in world.slots {
		slot.born = false
		if !slot.alive do continue
		sync_transform(&slot)
		if handle, ok := slot.emitter.?; ok {
			// Emitter follows its actor's Transform.
			if emitter := particles.emitter_get(world.particles, handle); emitter != nil do emitter.desc.position = slot_component(&slot, Transform).position
		}
		if playback, ok := &slot.playback.(gfx.Playback); ok do append(&playbacks, playback)
		advance_sprite_anim(&slot, dt)
	}
	// Each Playback owns its pose, so the ranges are disjoint.
	Tick :: struct {
		playbacks: []^gfx.Playback,
		dt:        f32,
	}
	tick := Tick{playbacks[:], dt}
	jobs.parallel_for(world.jobs, len(playbacks), &tick, proc(data: rawptr, first, last: int) {
		tick := (^Tick)(data)
		for p in tick.playbacks[first:last] do gfx.playback_tick(p, tick.dt)
	}, 8)
	if world.particles != nil do particles.system_update(world.particles, dt)
	update_environment(world)
	update_camera(world)
	update_camera_2d(world)
	script_gc_step(world)
}

// Ticks each registered actor that has fixed_tick once, at the caller's fixed step.
// Does not step physics or sync Transforms. A scene that sets fixed_tick = world_update
// (the physics scene) must not also call world_fixed_update, or physics steps twice.
world_fixed_update :: proc(world: ^World, dt: f32) {
	world.updating = true
	// Index loop: a fixed tick may spawn (reallocating slots) or destroy, so re-read each step.
	for index := 0; index < len(world.slots); index += 1 {
		slot := &world.slots[index]
		if !slot.alive || slot.born do continue
		info, ok := slot_type(world, slot)
		if !ok || info.fixed_tick == nil do continue
		info.fixed_tick(world, Actor_Id{u32(index), slot.generation}, slot.state, dt)
	}
	script_update(world, dt, .Fixed_Tick)
	world.updating = false
}

// Writes each Dynamic body's pose, blended between its last two physics steps, into its Transform.
world_render :: proc(world: ^World, blend := f32(1)) {
	for &slot in world.slots {
		body, ok := dynamic_body(&slot)
		if !ok do continue
		pos, rot := phys.tracked_blend(body^, blend)
		transform := slot_component(&slot, Transform)
		transform.position = pos
		transform.rotation = rot
		sync_transform(&slot)
	}
	if camera_2d_slot(world) != nil do world_draw_sprites(world) // before the frame: batch upload submits its own command buffer
	world_draw_hud(world)
	gfx.renderer_render_frame(&world.gfx_ctx.renderer, world_extract, world)
}

@(private = "file")
world_extract :: proc(renderer: ^gfx.Renderer, user: rawptr) {
	world := (^World)(user)
	view := gfx.renderer_begin_extract(renderer)
	draws := make([dynamic]^gfx.Draw, 0, len(world.slots), context.temp_allocator)
	for &slot in world.slots {
		if slot.alive && slot.draw.mesh != nil do append(&draws, &slot.draw)
	}
	if sky, ok := &world.sky.?; ok {
		draw := new(gfx.Draw, context.temp_allocator)
		draw^ = gfx.skybox_draw(sky)
		append(&draws, draw)
	}
	gfx.renderer_submit_draw_ptrs(renderer, &view, draws[:])
}

// Sprite_Draw is one queued sprite; sort keys are resolved before drawing.
@(private = "file")
Sprite_Draw :: struct {
	slot:    ^Slot,
	layer:   i32,
	depth:   f32,
	texture: gfx.Texture_Handle,
}

@(private = "file")
world_draw_sprites :: proc(world: ^World) {
	gfx_ctx := world.gfx_ctx
	batch, ok := &world.batch.?
	if !ok {
		world.batch = gfx.batch_create(gfx_ctx)
		batch = &world.batch.?
		gfx.batch_register(gfx_ctx, batch)
	}
	queue := make([dynamic]Sprite_Draw, context.temp_allocator)
	for &slot in world.slots {
		if !slot.alive do continue
		sprite := slot_component(&slot, Sprite)
		if sprite == nil do continue
		transform := slot_component(&slot, Transform)
		append(&queue, Sprite_Draw{slot = &slot, layer = sprite.layer, depth = transform.position.z, texture = asset_texture(world, sprite.texture)})
	}
	// Painter's order: layer, then depth. Texture breaks ties so runs stay long.
	slice.stable_sort_by(queue[:], proc(a, b: Sprite_Draw) -> bool {
		if a.layer != b.layer do return a.layer < b.layer
		if a.depth != b.depth do return a.depth < b.depth
		return a.texture.index < b.texture.index
	})
	gfx.batch_begin(batch, gfx_ctx, world.camera_2d)
	for draw in queue do sprite_push(batch, gfx_ctx, draw.slot, draw.texture)
	gfx.batch_end(batch, gfx_ctx)
}

@(private = "file")
sprite_push :: proc(batch: ^gfx.Batch, gfx_ctx: ^gfx.Device, slot: ^Slot, texture: gfx.Texture_Handle) {
	sprite := slot_component(slot, Sprite)
	transform := slot_component(slot, Transform)
	tex := gfx.texture_get(gfx_ctx, texture)
	texture_size := [2]f32{f32(tex.width), f32(tex.height)}
	cell := texture_size
	src: gfx.Rect // zero rect = whole image
	if sprite.grid != {} {
		cols, rows := max(sprite.grid.x, 1), max(sprite.grid.y, 1)
		cell = {texture_size.x / f32(cols), texture_size.y / f32(rows)}
		index := clamp(sprite.frame, 0, cols * rows - 1)
		src = {x = f32(index % cols) * cell.x, y = f32(index / cols) * cell.y, w = cell.x, h = cell.y}
	}
	origin, has_origin := sprite.origin.?
	if !has_origin do origin = {0.5, 0.5}
	color := sprite.color
	if color == {} do color = {1, 1, 1, 1}
	angle := 2 * math.atan2(transform.rotation.z, transform.rotation.w)
	size := [2]f32{cell.x * transform.scale.x, cell.y * transform.scale.y}
	gfx.batch_sprite(batch, texture, texture_size, transform.position.xy, size, src, color, origin, angle, sprite.flip_x, sprite.flip_y)
}

// Queues HUD text for this frame: position in window px, y down; color is sRGB.
// world_render draws and clears the queue, so call it every frame the text shows.
world_text :: proc(world: ^World, text: string, position: [2]f32, color := [4]f32{1, 1, 1, 1}) {
	append(&world.texts, Hud_Text{text = strings.clone(text, context.temp_allocator), position = position, color = gfx.color_srgb_to_linear(color)})
}

// Draws the queued HUD text in window px. An empty batch clears last frame's draw.
@(private = "file")
world_draw_hud :: proc(world: ^World) {
	gfx_ctx := world.gfx_ctx
	hud, ok := &world.hud.?
	if !ok {
		if len(world.texts) == 0 do return
		font, font_ok := gfx.font_create(gfx_ctx, HUD_FONT_PATH)
		assert(font_ok, "engine: HUD font not found")
		world.hud = Hud{batch = gfx.batch_create(gfx_ctx), font = font}
		hud = &world.hud.?
		gfx.batch_register(gfx_ctx, &hud.batch)
	}
	window := [2]f32{f32(gfx_ctx.window_size.x), f32(gfx_ctx.window_size.y)}
	gfx.batch_begin(&hud.batch, gfx_ctx, gfx.Camera2D{position = window / 2})
	for text in world.texts do gfx.batch_text(&hud.batch, &hud.font, text.text, text.position, text.color)
	gfx.batch_end(&hud.batch, gfx_ctx)
	clear(&world.texts)
}

@(private = "file")
camera_2d_slot :: proc(world: ^World) -> ^Slot {
	for &slot in world.slots do if slot.alive && slot_component(&slot, Camera_2D) != nil do return &slot
	return nil
}

@(private = "file")
update_camera_2d :: proc(world: ^World) {
	slot := camera_2d_slot(world)
	if slot == nil do return
	camera := slot_component(slot, Camera_2D)
	transform := slot_component(slot, Transform)
	world.camera_2d = gfx.Camera2D{position = transform.position.xy, zoom = camera.zoom, viewport = camera.viewport, integer_scale = camera.integer_scale}
}

@(private = "file")
advance_sprite_anim :: proc(slot: ^Slot, dt: f32) {
	anim := slot_component(slot, Sprite_Anim)
	if anim == nil do return
	anim.time += dt
	if sprite := slot_component(slot, Sprite); sprite != nil do sprite.frame = sprite_frame(anim^)
}

// Frame index at anim.time: loops wrap, otherwise it holds on last.
sprite_frame :: proc(anim: Sprite_Anim) -> i32 {
	count := int(anim.last - anim.first) + 1
	step := int(anim.time * anim.fps)
	if anim.loop {
		if count <= 0 do return anim.first
		return anim.first + i32(step % count)
	}
	return i32(min(int(anim.last), int(anim.first) + step))
}

// Rotation about Z, for Transform.rotation of a 2D actor.
rotation_2d :: proc(radians: f32) -> linalg.Quaternionf32 {
	return linalg.quaternion_angle_axis_f32(radians, {0, 0, 1})
}

// Mouse position in the 2D world (px) through the World's Camera_2D.
world_mouse :: proc(world: ^World, ctx: ^Context) -> [2]f32 {
	return gfx.screen_to_world(world.camera_2d, ctx.gfx.window_size, ctx.input.mouse_position)
}

@(private = "file")
update_camera :: proc(world: ^World) {
	for &slot in world.slots {
		if !slot.alive do continue
		camera := slot_component(&slot, Camera)
		if camera == nil do continue
		transform := slot_component(&slot, Transform)
		cam := gfx.camera(world.gfx_ctx)
		cam.position = transform.position
		if target, ok := camera.look_at.?; ok {
			cam.yaw, cam.pitch = direction_angles(target - transform.position)
		} else {
			forward := linalg.quaternion_mul_vector3(transform.rotation, Vec3{0, 0, -1})
			cam.yaw, cam.pitch = direction_angles(forward)
		}
		gfx.camera_rotate(cam, 0, 0) // rebuilds direction, right and up from yaw/pitch
		fov := camera.fov_y if camera.fov_y > 0 else gfx.CAMERA_FOV_Y
		gfx.camera_set_projection(cam, gfx.Perspective{fov_y = fov, near = gfx.CAMERA_NEAR}, gfx.aspect_ratio(world.gfx_ctx))
		set_effect_passes(world, camera)
		return
	}
}

// The first live Environment drives the renderer; nothing changes while none is live.
@(private = "file")
update_environment :: proc(world: ^World) {
	for &slot in world.slots {
		if !slot.alive do continue
		env := slot_component(&slot, Environment)
		if env == nil do continue
		assert(world.gfx_ctx != nil, "engine: Environment needs a world with a Device")
		apply_environment(world, env)
		return
	}
}

@(private = "file")
apply_environment :: proc(world: ^World, env: ^Environment) {
	gfx_ctx := world.gfx_ctx
	if fog, ok := env.fog.?; ok {
		rgb := gfx.color_srgb_to_linear({fog.color.x, fog.color.y, fog.color.z, 1})
		gfx_ctx.renderer.fog = {rgb.x, rgb.y, rgb.z, fog.distance}
	} else {
		gfx_ctx.renderer.fog = {}
	}
	if grade, ok := env.grade.?; ok {
		if world.tonemap == nil {
			world.tonemap = new(gfx.Tonemap)
			world.tonemap^ = gfx.tonemap_create(gfx_ctx)
		}
		gfx.tonemap_set(world.tonemap, grade.exposure, grade.contrast, grade.saturation)
		gfx.renderer_set_passes(&gfx_ctx.renderer, .Final, []gfx.Render_Pass{gfx.tonemap_pass(world.tonemap)})
	} else {
		gfx.renderer_clear_passes(&gfx_ctx.renderer, .Final)
	}
	shadows, shadows_set := env.shadows.?
	gfx_ctx.renderer.shadow_enabled = shadows if shadows_set else true
	sun, sun_set := env.sun_direction.?
	if !sun_set do sun = gfx.DEFAULT_LIGHT_DIRECTION
	gfx.renderer_update_light(&gfx_ctx.renderer, sun)
	if env.uncapped != world.uncapped {
		world.uncapped = env.uncapped
		gfx.set_present_mode(gfx_ctx, .IMMEDIATE if env.uncapped else .VSYNC)
	}
	update_sky(world, env.skybox)
}

// Rebuilds the skybox when its path changes; "" means no skybox.
@(private = "file")
update_sky :: proc(world: ^World, path: string) {
	if path == world.sky_path do return
	if sky, ok := &world.sky.?; ok do gfx.skybox_destroy(world.gfx_ctx, sky)
	world.sky = nil
	if len(world.sky_path) > 0 do delete(world.sky_path)
	world.sky_path = ""
	if path == "" do return
	world.sky = gfx.skybox_create(world.gfx_ctx, path)
	world.sky_path = strings.clone(path)
}

// Yaw and pitch of a view direction, in gfx.Camera's convention. A zero
// direction gives (0, 0).
direction_angles :: proc(direction: Vec3) -> (yaw, pitch: f32) {
	d := linalg.normalize0(direction)
	return math.atan2(d.z, d.x), math.asin(math.clamp(d.y, -1, 1))
}

// Creates each enabled effect once; later frames only update its settings.
// Blur runs before bloom.
@(private = "file")
set_effect_passes :: proc(world: ^World, camera: ^Camera) {
	passes: [2]gfx.Render_Pass
	count := 0
	if radius, ok := camera.blur.?; ok {
		if world.blur == nil {
			world.blur = new(gfx.Blur)
			world.blur^ = gfx.blur_create(world.gfx_ctx)
		}
		world.blur.radius = radius if radius > 0 else 4
		world.blur.radius = min(world.blur.radius, gfx.BLUR_MAX_RADIUS)
		passes[count] = gfx.blur_pass(world.blur)
		count += 1
	}
	if settings, ok := camera.bloom.?; ok {
		if world.bloom == nil {
			world.bloom = new(gfx.Bloom)
			world.bloom^ = gfx.bloom_create(world.gfx_ctx)
		}
		// Same values as gfx.bloom_create, applied to the existing pipelines.
		threshold := settings.threshold if settings.threshold > 0 else 0.8
		world.bloom.threshold = threshold
		world.bloom.knee = 0.5 * threshold
		world.bloom.intensity = settings.intensity if settings.intensity > 0 else 0.6
		world.bloom.radius = settings.radius if settings.radius > 0 else 6
		world.bloom.radius = min(world.bloom.radius, gfx.BLUR_MAX_RADIUS)
		passes[count] = gfx.bloom_pass(world.bloom)
		count += 1
	}
	gfx.renderer_set_passes(&world.gfx_ctx.renderer, .Post, passes[:count])
}

@(private = "file")
actor_type_info :: proc(world: ^World, type: Actor_Type, $T: typeid) -> Actor_Type_Info {
	assert(type != 0 && int(type) <= len(world.types), "engine: unknown Actor_Type")
	info := world.types[int(type) - 1]
	assert(info.state_size == size_of(T), "engine: state type does not match register_type")
	return info
}

@(private = "file")
slot_type :: proc(world: ^World, slot: ^Slot) -> (info: Actor_Type_Info, ok: bool) {
	if slot.type == 0 do return {}, false
	return world.types[int(slot.type) - 1], true
}

// Reuses a freed index when there is one. The generation was bumped on destroy.
@(private = "file")
claim_slot :: proc(world: ^World) -> u32 {
	index: u32
	if len(world.free) > 0 {
		index = pop(&world.free)
	} else {
		index = u32(len(world.slots))
		append(&world.slots, Slot{generation = 1})
	}
	slot := &world.slots[index]
	slot.alive = true
	slot.born = world.updating
	return index
}

slot_component :: proc(slot: ^Slot, $T: typeid) -> ^T {
	for block in slot.props do if block.type == typeid_of(T) do return (^T)(block.data)
	return nil
}

// Stores a copy of prop in the actor, replacing its Prop of the same type. With notify
// the replaced Prop's removed hook runs first; spawn passes false (no added hook ran yet).
@(private = "file")
store_prop :: proc(world: ^World, id: Actor_Id, prop: any, notify: bool) -> rawptr {
	info, known := world.props[prop.id]
	assert(known, "engine: props type not registered; call register_props")
	assert(type_info_of(prop.id).size == info.size, "engine: props size does not match register_props")
	slot := &world.slots[id.index]
	for &block in slot.props {
		if block.type != prop.id do continue
		if notify do run_removed(world, id, block.type, block.data)
		mem.copy(block.data, prop.data, info.size)
		return block.data
	}
	data, err := mem.alloc(info.size, info.align)
	assert(err == nil, "engine: out of memory for prop")
	mem.copy(data, prop.data, info.size)
	append(&slot.props, Prop_Block{type = prop.id, data = data})
	return data
}

@(private = "file")
run_added :: proc(world: ^World, id: Actor_Id, type: typeid, data: rawptr) {
	if info := world.props[type]; info.added != nil do info.added(world, id, data)
}

@(private = "file")
run_removed :: proc(world: ^World, id: Actor_Id, type: typeid, data: rawptr) {
	if info := world.props[type]; info.removed != nil do info.removed(world, id, data)
}

@(private = "file")
sync_transform :: proc(slot: ^Slot) {
	transform := slot_component(slot, Transform)
	slot.draw.transform = gfx.transform_trs(transform.position, transform.rotation, transform.scale)
}

// Builtin Prop hooks. The hook sees the stored copy, so changes to self stick.
@(private = "file")
transform_added :: proc(world: ^World, id: Actor_Id, self: ^Transform) {
	// Zero fields mean "unset": a zero quaternion is not a rotation, a zero scale collapses the actor.
	if self.scale == {} do self.scale = {1, 1, 1}
	if self.rotation == (linalg.Quaternionf32{}) do self.rotation = linalg.QUATERNIONF32_IDENTITY
}

@(private = "file")
name_added :: proc(world: ^World, id: Actor_Id, self: ^Name) {
	// The world owns the name: clone so the caller may free its string.
	self.value = strings.clone(self.value)
}

@(private = "file")
name_removed :: proc(world: ^World, id: Actor_Id, self: ^Name) {
	delete(self.value)
}

@(private = "file")
model_added :: proc(world: ^World, id: Actor_Id, self: ^Model) {
	assert(world.gfx_ctx != nil, "engine: Model needs a world with a Device")
	asset := asset_model(world, self.path)
	slot := &world.slots[id.index]
	slot.draw = gfx.draw_make(&asset.model.mesh, &asset.model.material)
	slot.draw.cull = !asset.skinned
	sync_transform(slot)
	if asset.skinned {
		playback := gfx.playback_create(&asset.model.skin)
		slot.draw.pose = playback.pose
		slot.playback = playback
	}
	apply_animator(slot)
}

@(private = "file")
model_removed :: proc(world: ^World, id: Actor_Id, self: ^Model) {
	remove_renderable(world, &world.slots[id.index])
}

@(private = "file")
raw_draw_added :: proc(world: ^World, id: Actor_Id, self: ^Raw_Draw) {
	assert(world.gfx_ctx != nil, "engine: Raw_Draw needs a world with a Device")
	mesh := new(gfx.Mesh)
	if len(self.mesh.indices) == 0 {
		mesh^ = gfx.mesh_create_unindexed(world.gfx_ctx, self.mesh.vertices)
	} else {
		mesh^ = gfx.mesh_create(world.gfx_ctx, self.mesh.vertices, self.mesh.indices)
	}
	slot := &world.slots[id.index]
	slot.owned_mesh = mesh
	slot.draw = gfx.draw_make(mesh, self.material)
	sync_transform(slot)
}

@(private = "file")
raw_draw_removed :: proc(world: ^World, id: Actor_Id, self: ^Raw_Draw) {
	remove_renderable(world, &world.slots[id.index])
}

@(private = "file")
animator_added :: proc(world: ^World, id: Actor_Id, self: ^Animator) {
	apply_animator(&world.slots[id.index])
}

@(private = "file")
emitter_added :: proc(world: ^World, id: Actor_Id, self: ^Particle_Emitter) {
	assert(world.gfx_ctx != nil, "engine: Particle_Emitter needs a world with a Device")
	// One system serves every emitter; created on the first one, like bloom/blur.
	if world.particles == nil do world.particles = particles.system_create(&world.gfx_ctx.renderer)
	slot := &world.slots[id.index]
	desc := self^
	desc.position = slot_component(slot, Transform).position
	slot.emitter = particles.emitter_add(world.particles, desc)
}

@(private = "file")
emitter_removed :: proc(world: ^World, id: Actor_Id, self: ^Particle_Emitter) {
	remove_emitter(world, &world.slots[id.index])
}

// Dynamic Collider's body. Static bodies return false: the scene owns their Transform.
@(private = "file")
dynamic_body :: proc(slot: ^Slot) -> (^phys.Tracked, bool) {
	collider := slot_component(slot, Collider)
	if collider == nil || collider.body != .Dynamic do return nil, false
	if body, ok := &slot.body.?; ok do return body, true
	return nil, false
}

@(private = "file")
collider_added :: proc(world: ^World, id: Actor_Id, self: ^Collider) {
	if _, ok := world.physics.?; !ok do world.physics = phys.create(world.gravity)
	world_phys := world.physics.?
	slot := &world.slots[id.index]
	// shortcut: the Transform rotation is ignored, bodies start unrotated; upgrade when a scene needs rotated bodies.
	pos := slot_component(slot, Transform).position
	density := self.density
	if density == 0 do density = 1
	tracked: phys.Tracked
	switch shape in self.shape {
	case Box:
		switch self.body {
		case .Static: tracked = phys.track(phys.body_static(world_phys, pos, shape.half))
		case .Dynamic: tracked = phys.track(phys.body_box(world_phys, pos, shape.half, density))
		}
	case Sphere:
		assert(self.body == .Dynamic, "engine: static Sphere Collider is not supported; use a Box")
		tracked = phys.track(phys.body_sphere(world_phys, pos, shape.radius, density))
	case nil:
		assert(false, "engine: Collider needs a shape")
	}
	slot.body = tracked
	if world.contact_actors == nil do world.contact_actors = make(map[phys.Body]Actor_Id)
	world.contact_actors[tracked.body] = id
}

@(private = "file")
collider_removed :: proc(world: ^World, id: Actor_Id, self: ^Collider) {
	slot := &world.slots[id.index]
	if tracked, ok := slot.body.?; ok do delete_key(&world.contact_actors, tracked.body)
	if tracked, ok := slot.body.?; ok do phys.body_destroy(tracked.body)
	slot.body = nil
}

// Runs contact hooks for each begin-touch pair: Odin contact, then Lua on_contact, per side.
// A hook may destroy either actor, so every call re-checks both ids.
@(private = "file")
dispatch_contacts :: proc(world: ^World, pairs: []phys.Contact_Pair) {
	for pair in pairs {
		a, ok_a := world.contact_actors[pair.a]
		b, ok_b := world.contact_actors[pair.b]
		if !ok_a || !ok_b do continue
		contact_notify(world, a, b)
		contact_notify(world, b, a)
	}
}

@(private = "file")
contact_notify :: proc(world: ^World, id, other: Actor_Id) {
	if !world_valid(world, id) || !world_valid(world, other) do return
	slot := &world.slots[id.index]
	if info, ok := slot_type(world, slot); ok && info.contact != nil do info.contact(world, id, slot.state, other)
	if !world_valid(world, id) || !world_valid(world, other) do return
	script_contact(world, id, other)
}

// Plays the Animator on the slot's skinned Model; no-op until the Model is built.
@(private = "file")
apply_animator :: proc(slot: ^Slot) {
	animator := slot_component(slot, Animator)
	if animator == nil || slot.draw.mesh == nil do return
	playback, has_skin := &slot.playback.(gfx.Playback)
	if !has_skin {
		log.errorf("engine: Animator on a model without a skin")
		return
	}
	if !gfx.playback_play(playback, animator.clip) {
		log.errorf("engine: clip %q not found", animator.clip)
		// Rest pose until a valid clip is named.
		playback.clip = -1
		playback.time = 0
		gfx.clip_sample(playback.skin, -1, 0, playback.pose)
	}
}

@(private = "file")
remove_renderable :: proc(world: ^World, slot: ^Slot) {
	if playback, ok := &slot.playback.(gfx.Playback); ok do gfx.playback_destroy(playback)
	slot.playback = nil
	if slot.owned_mesh != nil {
		gfx.mesh_destroy(world.gfx_ctx, slot.owned_mesh)
		free(slot.owned_mesh)
		slot.owned_mesh = nil
	}
	slot.draw = {}
}

@(private = "file")
remove_emitter :: proc(world: ^World, slot: ^Slot) {
	if handle, ok := slot.emitter.?; ok do particles.emitter_remove(world.particles, handle)
	slot.emitter = nil
}

// Runs each Prop's removed hook (last added first), then frees Props, state and slot.
@(private = "file")
destroy_slot :: proc(world: ^World, id: Actor_Id) {
	slot := &world.slots[id.index]
	#reverse for block in slot.props {
		run_removed(world, id, block.type, block.data)
		free(block.data)
	}
	delete(slot.props)
	slot.props = nil
	if slot.state != nil do free(slot.state)
	slot.state = nil
	slot.type = 0
	slot.alive = false
	slot.generation += 1
}
