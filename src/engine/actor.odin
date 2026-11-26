package engine

import "base:runtime"
import "core:mem"
import "core:slice"
import "core:math/linalg"

// Prop of a world_add_actor struct: its type and byte offset inside the actor's block.
Embedded_Prop :: struct {
	type:   typeid,
	offset: uintptr,
}

// Hook procs typed to the user struct T; stored as the untyped Actor hooks.
actor_hooks :: proc(
	$T: typeid,
	tick: proc(self: ^T, dt: f32) = nil,
	fixed_tick: proc(self: ^T, dt: f32) = nil,
	destroy: proc(self: ^T) = nil,
	contact: proc(self: ^T, other: Actor_Id) = nil,
	lua: string = "",
) -> Actor {
	actor: Actor
	if tick != nil do actor.tick = transmute(proc(self: ^Actor, dt: f32))tick
	if fixed_tick != nil do actor.fixed_tick = transmute(proc(self: ^Actor, dt: f32))fixed_tick
	if destroy != nil do actor.destroy = transmute(proc(self: ^Actor))destroy
	if contact != nil do actor.contact = transmute(proc(self: ^Actor, other: Actor_Id))contact
	actor.lua = lua
	return actor
}

// Actor handle of a slot added by world_add_actor; nil for spawn slots.
actor_of :: proc(slot: ^Slot) -> ^Actor {
	if slot.type_id == nil do return nil
	return (^Actor)(slot.state)
}

// Layout of the registered Props in T, cached per world. Fails when Actor is not the first field.
embedded_layout :: proc(world: ^World, T: typeid) -> ([]Embedded_Prop, bool) {
	if layout, ok := world.embedded_props[T]; ok do return layout, true
	info, is_struct := runtime.type_info_base(type_info_of(T)).variant.(runtime.Type_Info_Struct)
	if !is_struct || info.field_count == 0 do return nil, false
	if info.types[0].id != typeid_of(Actor) || !info.usings[0] || info.offsets[0] != 0 do return nil, false

	found: [dynamic]Embedded_Prop
	defer delete(found)
	for i in 0 ..< int(info.field_count) {
		field := info.types[i].id
		if _, known := world.props[field]; !known do continue
		for prop in found do assert(prop.type != field, "engine: two fields of one Prop type in an actor struct")
		append(&found, Embedded_Prop{type = field, offset = info.offsets[i]})
	}

	if world.embedded_props == nil do world.embedded_props = make(map[typeid][]Embedded_Prop)
	layout := slice.clone(found[:])
	world.embedded_props[T] = layout
	return layout, true
}

// Adds value as an actor: the struct's Props live in its block, with no per-Prop allocation.
world_add_actor :: proc(world: ^World, value: $T) -> ^T {
	layout, ok := embedded_layout(world, typeid_of(T))
	assert(ok, "engine: world_add_actor needs `using actor: Actor` as the first field")

	block, err := mem.alloc(size_of(T), align_of(T))
	assert(err == nil, "engine: out of memory for actor")
	(^T)(block)^ = value

	index := claim_slot(world)
	id := Actor_Id{index, world.slots[index].generation}
	actor := (^Actor)(block)
	actor.world = world
	actor.id = id
	world.slots[index].state = block
	world.slots[index].type_id = typeid_of(T)

	// Transform first, as spawn: added hooks read the normalized transform.
	transform := typeid_of(Transform)
	has_transform := false
	for prop in layout do if prop.type == transform do has_transform = true
	if !has_transform do store_prop(world, id, Transform{}, false)
	for prop in layout do if prop.type == transform do append_embedded(world, index, block, prop)
	for prop in layout do if prop.type != transform do append_embedded(world, index, block, prop)

	// actor.lua becomes a Script prop unless T embeds one, which then wins.
	has_script := false
	for prop in layout do if prop.type == typeid_of(Script) do has_script = true
	if actor.lua != "" && !has_script do store_prop(world, id, Script{path = actor.lua}, false)

	count := len(world.slots[index].props)
	for i in 0 ..< count {
		props := world.slots[index].props
		if i >= len(props) do break
		run_added(world, id, props[i].type, props[i].data)
	}
	sync_transform(&world.slots[index])
	return (^T)(block)
}

@(private = "file")
append_embedded :: proc(world: ^World, index: u32, block: rawptr, prop: Embedded_Prop) {
	append(&world.slots[index].props, Prop_Block{type = prop.type, data = rawptr(uintptr(block) + prop.offset), embedded = true})
}

// Pointer to the actor's struct T; nil for invalid ids or a different type.
world_get :: proc(world: ^World, id: Actor_Id, $T: typeid) -> ^T {
	if !world_valid(world, id) do return nil
	slot := &world.slots[id.index]
	if slot.type_id != typeid_of(T) do return nil
	return (^T)(slot.state)
}

// First live actor of struct type T.
world_find :: proc(world: ^World, $T: typeid) -> ^T {
	for &slot in world.slots do if slot.alive && slot.type_id == typeid_of(T) do return (^T)(slot.state)
	return nil
}

// Live actors of struct type T.
world_count :: proc(world: ^World, $T: typeid) -> int {
	count := 0
	for &slot in world.slots do if slot.alive && slot.type_id == typeid_of(T) do count += 1
	return count
}

// Replaces the actor's Model; the setter is the entry point, so the Prop is rebuilt through actor_add_props.
model_set :: proc(actor: ^Actor, path: string) {
	actor_add_props(actor.world, actor.id, Model{path = path})
}

// Plays clip on the actor's Animator; the setter is the entry point, so the Prop goes through actor_add_props.
animator_play :: proc(actor: ^Actor, clip: string) {
	actor_add_props(actor.world, actor.id, Animator{clip = clip})
}

transform_create :: proc(
	position := Vec3{},
	rotation := linalg.QUATERNIONF32_IDENTITY,
	scale := Vec3{1, 1, 1},
) -> Transform {
	return Transform{position = position, rotation = rotation, scale = scale}
}

model_create :: proc(path: string) -> Model {
	return Model{path = path}
}
