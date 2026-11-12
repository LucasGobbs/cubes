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
//       // edit any Transform here: engine.get(world, app.hero, engine.Transform)
//   }
//
// Per-entity logic (registry): a state struct plus create/tick/destroy procs.
//   Ship :: struct { target: engine.Entity_Type }
//   ship_create :: proc(world: ^engine.World, id: engine.Entity_Id, self: ^Ship) { /* world_add components */ }
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
import gfx "gfx"

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

// Plain data: game code reads and writes current through get.
Health :: struct {
	current, max: f32,
}

Component :: union {
	Transform,
	Model,
	Animator,
	Camera,
	Camera_2D,
	Sprite,
	Sprite_Anim,
	Health,
}

World :: struct {
	gfx_ctx:  ^gfx.Device, // nil is fine for worlds that only hold Transforms (tests)
	slots:    [dynamic]Slot,
	free:     [dynamic]u32,
	types:    [dynamic]Entity_Type_Info,
	assets:   Assets,
	updating: bool, // true while world_update ticks; spawns then wait one frame
	// Effects are heap-allocated on first use: render passes point at them.
	bloom:    ^gfx.Bloom,
	blur:     ^gfx.Blur,
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
}

// Use world_create; a zero World has no asset cache.
world_create :: proc(gfx_ctx: ^gfx.Device) -> World {
	return World{gfx_ctx = gfx_ctx, assets = {models = make(map[string]^Model_Asset)}}
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

world_valid :: proc(world: ^World, id: Entity_Id) -> bool {
	if int(id.index) >= len(world.slots) do return false
	slot := &world.slots[id.index]
	return slot.alive && slot.generation == id.generation
}

// Pointer into the component storage: valid until the next world_add or spawn.
get :: proc(world: ^World, id: Entity_Id, $T: typeid) -> ^T {
	if !world_valid(world, id) do return nil
	return slot_component(&world.slots[id.index], T)
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

world_add :: proc(world: ^World, id: Entity_Id, component: Component) {
	assert(world_valid(world, id), "engine: world_add on invalid entity")
	slot := &world.slots[id.index]
	set_component(slot, component)
	sync_transform(slot)
	slot_resolve(world, slot)
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
	for &slot in world.slots {
		slot.born = false
		if !slot.alive do continue
		sync_transform(&slot)
		if playback, ok := &slot.playback.(gfx.Playback); ok do gfx.playback_tick(playback, dt)
		advance_sprite_anim(&slot, dt)
	}
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
	for &slot in world.slots {
		if slot.alive && slot.draw.mesh != nil do gfx.renderer_submit_draw(renderer, &view, &slot.draw)
	}
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
		cam.projection = gfx.camera_perspective(gfx.aspect_ratio(world.gfx_ctx), fov)
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
	// A new Model needs a new renderable; the old one is dropped by slot_resolve.
	if _, is_model := value.(Model); is_model do remove_renderable(slot)
	kind := reflect.union_variant_typeid(value)
	for &existing in slot.components {
		if reflect.union_variant_typeid(existing) == kind {
			existing = value
			return
		}
	}
	append(&slot.components, value)
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
destroy_slot :: proc(slot: ^Slot) {
	remove_renderable(slot)
	delete(slot.components)
	slot.components = nil
	if slot.state != nil do free(slot.state)
	slot.state = nil
	slot.type = 0
	slot.alive = false
	slot.generation += 1
}
