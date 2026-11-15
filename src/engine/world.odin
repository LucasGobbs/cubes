// Entity x component world on top of gfx. Spawn entities with components;
// models, pipelines, skins, camera and post-process passes are resolved here.
//
// Recipe (examples/hello_engine/main.odin):
//   App :: struct { hero: engine.Entity_Id }
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
//       // edit any Transform here: engine.entity_get_component(world, app.hero, engine.Transform)
//   }
//
// Per-entity logic (registry): a state struct plus create/tick/destroy procs.
//   Ship :: struct { target: engine.Entity_Type }
//   ship_create :: proc(world: ^engine.World, id: engine.Entity_Id, self: ^Ship) { /* entity_add_component */ }
//   ship_tick :: proc(world: ^engine.World, id: engine.Entity_Id, self: ^Ship, dt: f32) { /* ... */ }
//   // start:  ship := engine.register_type(world, Ship, ship_create, ship_tick, nil)
//   // spawn:  engine.spawn_typed(world, ship, Ship{target = player_type})
// Ticks run in slot order (spawn order, reused slots included), once per world_update.
// Entities spawned during world_update first tick on the next one.
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

Vec3 :: gfx.Vec3

// Generation 0 is never a live slot, so the zero Entity_Id is always invalid.
Entity_Id :: struct {
	index, generation: u32,
}

// Handle from register_type. Zero is invalid; handles are 1-based indices into World.types.
Entity_Type :: distinct u32

// Procs are stored type-erased. The state is a heap block owned by the slot.
Entity_Type_Info :: struct {
	state_size, state_align: int,
	create:                  proc(world: ^World, id: Entity_Id, state: rawptr),
	tick:                    proc(world: ^World, id: Entity_Id, state: rawptr, dt: f32),
	destroy:                 proc(world: ^World, id: Entity_Id, state: rawptr),
}

Transform :: struct {
	position: Vec3,
	rotation: linalg.Quaternionf32,
	scale:    Vec3,
}

// path is borrowed: the string must outlive the entity.
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

// The first live entity with a Camera drives the renderer camera. Its position
// comes from its Transform; look_at (a world point) overrides the Transform rotation.
// fov_y 0 => gfx.CAMERA_FOV_Y. bloom and blur enable those post effects for the
// frame; blur is a radius in texels, 0 => 4.
Camera :: struct {
	fov_y:   f32,
	look_at: Maybe(Vec3),
	bloom:   Maybe(Bloom),
	blur:    Maybe(i32),
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

// The first live entity with a Camera_2D drives the 2D view; its position comes
// from Transform.position.xy (world px).
Camera_2D :: struct {
	zoom:          f32, // 0 = 1
	viewport:      [2]f32, // logical resolution; {0,0} = window size
	integer_scale: bool,
}

// Plain data: game code reads and writes current through entity_get_component.
Health :: struct {
	current, max: f32,
}

// Entity name: key for world_find_by_name and hot reload. The world clones value on set.
Name :: struct {
	value: string,
}

// Emitter spawned at the entity Transform position; needs a World with a Device.
Particle_Emitter :: particles.Emitter_Desc

Component :: union {
	Transform,
	Model,
	Animator,
	Camera,
	Camera_2D,
	Sprite,
	Sprite_Anim,
	Health,
	Name,
	Particle_Emitter,
}

World :: struct {
	gfx_ctx:  ^gfx.Device, // nil is fine for worlds that only hold Transforms (tests)
	jobs:     ^jobs.Pool, // borrowed from the renderer; nil = serial
	slots:    [dynamic]Slot,
	free:     [dynamic]u32,
	types:    [dynamic]Entity_Type_Info,
	assets:   Assets,
	updating: bool, // true while world_update ticks; spawns then wait one frame
	// Effects are heap-allocated on first use: render passes point at them.
	bloom:    ^gfx.Bloom,
	blur:     ^gfx.Blur,
	particles: ^particles.System, // lazy like bloom/blur: created on the first Particle_Emitter
	// 2D batch and view: the batch is created on the first frame with a Camera_2D
	// and its render pass keeps its address, so the World must not move after that.
	batch:     Maybe(gfx.Batch),
	camera_2d: gfx.Camera2D,
}

Slot :: struct {
	generation: u32,
	alive:      bool,
	born:       bool, // spawned during the current world_update: skip its tick
	components: [dynamic]Component,
	draw:       gfx.Draw,
	playback:   Maybe(gfx.Playback), // skinned Models only
	type:       Entity_Type, // 0 when the entity has no registered type
	state:      rawptr,
	emitter:    Maybe(particles.Emitter_Handle), // this entity's emitter; nil when none
}

// Use world_create; a zero World has no asset cache.
world_create :: proc(gfx_ctx: ^gfx.Device) -> World {
	return World{gfx_ctx = gfx_ctx, jobs = gfx_ctx.renderer.jobs if gfx_ctx != nil else nil, assets = {models = make(map[string]^Model_Asset)}}
}

// Registers a per-entity state type. create runs after spawn, tick once per
// world_update, destroy before the entity's components are freed. Any proc may be nil.
register_type :: proc(
	world: ^World,
	$T: typeid,
	create: proc(world: ^World, id: Entity_Id, self: ^T),
	tick: proc(world: ^World, id: Entity_Id, self: ^T, dt: f32),
	destroy: proc(world: ^World, id: Entity_Id, self: ^T),
) -> Entity_Type {
	info := Entity_Type_Info{state_size = size_of(T), state_align = align_of(T)}
	// Same ABI trick as run: only the pointer parameter type differs.
	if create != nil do info.create = transmute(proc(^World, Entity_Id, rawptr))create
	if tick != nil do info.tick = transmute(proc(^World, Entity_Id, rawptr, f32))tick
	if destroy != nil do info.destroy = transmute(proc(^World, Entity_Id, rawptr))destroy
	append(&world.types, info)
	return Entity_Type(len(world.types))
}

// Copies init into a new state block, spawns the components, then runs create.
// The returned pointer is stable until the entity is destroyed; if create destroys
// the entity, the pointer dangles. Components of one type replace the existing one.
// Every entity gets a Transform (a default one when none is given).
spawn_typed :: proc(world: ^World, type: Entity_Type, init: $T, components: ..Component) -> (Entity_Id, ^T) {
	info := entity_type_info(world, type, T)
	state, err := mem.alloc(info.state_size, info.state_align)
	assert(err == nil, "engine: out of memory for entity state")
	(^T)(state)^ = init
	id := spawn(world, ..components)
	slot := &world.slots[id.index]
	slot.type = type
	slot.state = state
	if info.create != nil do info.create(world, id, state)
	return id, (^T)(state)
}

// Components of one type replace the existing one. Every entity gets a
// Transform (a default one when none is given).
spawn :: proc(world: ^World, components: ..Component) -> Entity_Id {
	index := claim_slot(world)
	slot := &world.slots[index]
	for component in components do set_component(slot, component)
	if slot_component(slot, Transform) == nil do set_component(slot, Transform{})
	sync_transform(slot)
	slot_resolve(world, slot)
	return Entity_Id{index, slot.generation}
}

// Spawns a 3D camera at position looking at look_at; fov_y 0 => gfx.CAMERA_FOV_Y.
// For bloom or blur, spawn a Camera literal instead.
spawn_camera :: proc(world: ^World, position: Vec3, look_at := Vec3{}, fov_y: f32 = 0) -> Entity_Id {
	return spawn(world, Camera{fov_y = fov_y, look_at = look_at}, Transform{position = position})
}

world_valid :: proc(world: ^World, id: Entity_Id) -> bool {
	if int(id.index) >= len(world.slots) do return false
	slot := &world.slots[id.index]
	return slot.alive && slot.generation == id.generation
}

// Pointer into the component storage: valid until the next entity_add_component or spawn.
entity_get_component :: proc(world: ^World, id: Entity_Id, $T: typeid) -> ^T {
	if !world_valid(world, id) do return nil
	return slot_component(&world.slots[id.index], T)
}

// First live entity whose Name equals name. Returns the zero Entity_Id and false if none.
world_find_by_name :: proc(world: ^World, name: string) -> (Entity_Id, bool) {
	for &slot, index in world.slots {
		if !slot.alive do continue
		if component := slot_component(&slot, Name); component != nil && component.value == name {
			return Entity_Id{u32(index), slot.generation}, true
		}
	}
	return {}, false
}

// Live entities in slot order (temp allocator).
world_entities :: proc(world: ^World) -> []Entity_Id {
	list := make([dynamic]Entity_Id, context.temp_allocator)
	for &slot, index in world.slots do if slot.alive do append(&list, Entity_Id{u32(index), slot.generation})
	return list[:]
}

// State of an entity spawned with spawn_typed. Nil for invalid ids.
world_get_state :: proc(world: ^World, id: Entity_Id, $T: typeid) -> ^T {
	if !world_valid(world, id) do return nil
	slot := &world.slots[id.index]
	if _, ok := slot_type(world, slot); !ok do return nil
	_ = entity_type_info(world, slot.type, T)
	return (^T)(slot.state)
}

// First live entity of type, in slot order. Returns the zero Entity_Id and nil if none.
world_find_state :: proc(world: ^World, type: Entity_Type, $T: typeid) -> (Entity_Id, ^T) {
	_ = entity_type_info(world, type, T)
	for &slot, index in world.slots {
		if slot.alive && slot.type == type do return Entity_Id{u32(index), slot.generation}, (^T)(slot.state)
	}
	return {}, nil
}

// Live entities of type.
world_count :: proc(world: ^World, type: Entity_Type) -> int {
	count := 0
	for &slot in world.slots do if slot.alive && slot.type == type do count += 1
	return count
}

entity_add_component :: proc(world: ^World, id: Entity_Id, component: Component) {
	assert(world_valid(world, id), "engine: entity_add_component on invalid entity")
	slot := &world.slots[id.index]
	// Replacing an emitter: drop the old one; slot_resolve builds the new one.
	if _, ok := component.(Particle_Emitter); ok do remove_emitter(world, slot)
	set_component(slot, component)
	sync_transform(slot)
	slot_resolve(world, slot)
}

// Removes a component of type T; Transform cannot be removed. Removing Model drops its renderable.
entity_remove_component :: proc(world: ^World, id: Entity_Id, $T: typeid) {
	assert(T != Transform, "engine: Transform cannot be removed")
	if !world_valid(world, id) do return
	slot := &world.slots[id.index]
	for component, index in slot.components {
		if _, ok := component.(T); ok {
			free_component(component)
			ordered_remove(&slot.components, index)
			break
		}
	}
	if T == Model do remove_renderable(slot)
	if T == Particle_Emitter do remove_emitter(world, slot)
	sync_transform(slot)
	slot_resolve(world, slot)
}

// Transform of a live entity, nil if the id is invalid. Every entity has one from spawn.
entity_transform :: proc(world: ^World, id: Entity_Id) -> ^Transform {
	return entity_get_component(world, id, Transform)
}

// Replaces the entity's Transform. Zero rotation or scale mean defaults, as in spawn.
entity_set_transform :: proc(world: ^World, id: Entity_Id, position := Vec3{}, rotation := linalg.QUATERNIONF32_IDENTITY, scale := Vec3{1, 1, 1}) {
	entity_add_component(world, id, Transform{position = position, rotation = rotation, scale = scale})
}

// Runs the entity's destroy proc while its components are still alive, then frees
// the state and components. No-op for invalid ids, so a stale id can be destroyed
// twice safely. A destroy proc must not destroy its own id.
world_destroy_entity :: proc(world: ^World, id: Entity_Id) {
	if !world_valid(world, id) do return
	if info, ok := slot_type(world, &world.slots[id.index]); ok && info.destroy != nil {
		info.destroy(world, id, world.slots[id.index].state)
		// The destroy proc may have destroyed other entities, or this one.
		if !world_valid(world, id) do return
	}
	remove_emitter(world, &world.slots[id.index])
	destroy_slot(&world.slots[id.index])
	append(&world.free, id.index)
}

// Destroys every live entity of type (their destroy procs run).
world_destroy_type :: proc(world: ^World, type: Entity_Type) {
	for index := 0; index < len(world.slots); index += 1 {
		slot := world.slots[index]
		if slot.alive && slot.type == type do world_destroy_entity(world, Entity_Id{u32(index), slot.generation})
	}
}

// Frees every entity, cached asset and effect. Clears the Post passes this world
// may have set on the renderer. Compute pipelines are freed with the Device.
world_destroy :: proc(world: ^World) {
	if world.gfx_ctx != nil {
		if batch, ok := &world.batch.?; ok do gfx.batch_destroy(world.gfx_ctx, batch)
		gfx.renderer_clear_passes(&world.gfx_ctx.renderer, .Post)
		world.gfx_ctx.renderer.clear_color = gfx.DEFAULT_CLEAR_COLOR
	}
	for index := 0; index < len(world.slots); index += 1 {
		slot := world.slots[index]
		if slot.alive do world_destroy_entity(world, Entity_Id{u32(index), slot.generation})
	}
	delete(world.slots)
	delete(world.free)
	delete(world.types)
	assets_destroy(world)
	free(world.bloom)
	free(world.blur)
	if world.particles != nil {
		particles.system_destroy(world.particles)
		world.particles = nil
	}
	world^ = {}
}

// Ticks each registered entity once, then copies each Transform into its entity,
// ticks animations, and applies the first Camera to the renderer. Ticks run in slot
// order, so the player is ticked before enemies when it is spawned first.
world_update :: proc(world: ^World, dt: f32) {
	world.updating = true
	// Index loop: a tick may spawn (reallocating slots) or destroy, so re-read each step.
	for index := 0; index < len(world.slots); index += 1 {
		slot := &world.slots[index]
		if !slot.alive || slot.born do continue
		info, ok := slot_type(world, slot)
		if !ok || info.tick == nil do continue
		info.tick(world, Entity_Id{u32(index), slot.generation}, slot.state, dt)
	}
	world.updating = false
	playbacks := make([dynamic]^gfx.Playback, 0, 0, context.temp_allocator)
	for &slot in world.slots {
		slot.born = false
		if !slot.alive do continue
		sync_transform(&slot)
		if handle, ok := slot.emitter.?; ok {
			// Emitter follows its entity's Transform.
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
	update_camera(world)
	update_camera_2d(world)
}

world_render :: proc(world: ^World) {
	if camera_2d_slot(world) != nil do world_draw_sprites(world) // before the frame: batch upload submits its own command buffer
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

// Rotation about Z, for Transform.rotation of a 2D entity.
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
entity_type_info :: proc(world: ^World, type: Entity_Type, $T: typeid) -> Entity_Type_Info {
	assert(type != 0 && int(type) <= len(world.types), "engine: unknown Entity_Type")
	info := world.types[int(type) - 1]
	assert(info.state_size == size_of(T), "engine: state type does not match register_type")
	return info
}

@(private = "file")
slot_type :: proc(world: ^World, slot: ^Slot) -> (info: Entity_Type_Info, ok: bool) {
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

@(private = "file")
slot_component :: proc(slot: ^Slot, $T: typeid) -> ^T {
	for &component in slot.components {
		if value, ok := &component.(T); ok do return value
	}
	return nil
}

@(private = "file")
set_component :: proc(slot: ^Slot, component: Component) {
	value := component
	if transform, ok := &value.(Transform); ok do normalize_transform(transform)
	// The world owns the name: clone so the caller may free its string.
	if name, ok := &value.(Name); ok do name.value = strings.clone(name.value)
	// A new Model needs a new renderable; the old one is dropped by slot_resolve.
	if _, is_model := value.(Model); is_model do remove_renderable(slot)
	kind := reflect.union_variant_typeid(value)
	for &existing in slot.components {
		if reflect.union_variant_typeid(existing) == kind {
			free_component(existing)
			existing = value
			return
		}
	}
	append(&slot.components, value)
}

// Frees what the world owns inside a component (the Name clone).
@(private = "file")
free_component :: proc(component: Component) {
	if name, ok := component.(Name); ok do delete(name.value)
}

// Zero fields mean "unset": a zero quaternion is not a rotation and a zero scale
// would collapse the entity.
@(private = "file")
normalize_transform :: proc(transform: ^Transform) {
	if transform.scale == {} do transform.scale = {1, 1, 1}
	if transform.rotation == (linalg.Quaternionf32{}) do transform.rotation = linalg.QUATERNIONF32_IDENTITY
}
@(private = "file")
sync_transform :: proc(slot: ^Slot) {
	transform := slot_component(slot, Transform)
	slot.draw.transform = gfx.transform_trs(transform.position, transform.rotation, transform.scale)
}

// Builds the draw for a Model and applies an Animator. Idempotent: run
// after every change to the slot's components.
@(private = "file")
slot_resolve :: proc(world: ^World, slot: ^Slot) {
	if emitter := slot_component(slot, Particle_Emitter); emitter != nil && slot.emitter == nil {
		assert(world.gfx_ctx != nil, "engine: Particle_Emitter needs a world with a Device")
		// One system serves every emitter; created on the first one, like bloom/blur.
		if world.particles == nil do world.particles = particles.system_create(&world.gfx_ctx.renderer)
		desc := emitter^
		desc.position = slot_component(slot, Transform).position
		slot.emitter = particles.emitter_add(world.particles, desc)
	}
	if model := slot_component(slot, Model); model != nil && slot.draw.mesh == nil {
		assert(world.gfx_ctx != nil, "engine: Model needs a world with a Device")
		asset := asset_model(world, model.path)
		slot.draw = gfx.draw_make(&asset.model.mesh, &asset.model.material)
		slot.draw.cull = !asset.skinned
		sync_transform(slot)
		if asset.skinned {
			playback := gfx.playback_create(&asset.model.skin)
			slot.draw.pose = playback.pose
			slot.playback = playback
		}
	}

	animator := slot_component(slot, Animator)
	if animator == nil || slot.draw.mesh == nil do return
	playback, has_skin := &slot.playback.(gfx.Playback)
	if !has_skin {
		log.errorf("engine: Animator on a model without a skin")
		return
	}
	if !gfx.playback_play(playback, animator.clip) {
		// Rest pose until a valid clip is named.
		log.errorf("engine: clip %q not found", animator.clip)
		playback.clip = -1
		playback.time = 0
		gfx.clip_sample(playback.skin, -1, 0, playback.pose)
	}
}

@(private = "file")
remove_renderable :: proc(slot: ^Slot) {
	if playback, ok := &slot.playback.(gfx.Playback); ok do gfx.playback_destroy(playback)
	slot.playback = nil
	slot.draw = {}
}

@(private = "file")
remove_emitter :: proc(world: ^World, slot: ^Slot) {
	if handle, ok := slot.emitter.?; ok do particles.emitter_remove(world.particles, handle)
	slot.emitter = nil
}

@(private = "file")
destroy_slot :: proc(slot: ^Slot) {
	remove_renderable(slot)
	for component in slot.components do free_component(component)
	delete(slot.components)
	slot.components = nil
	if slot.state != nil do free(slot.state)
	slot.state = nil
	slot.type = 0
	slot.alive = false
	slot.generation += 1
}
