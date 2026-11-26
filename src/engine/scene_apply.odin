package engine

import "core:log"

// Hot reload: makes the live world match def. Actors match by Name; Props
// equal by value are refreshed in place (no renderable rebuild), changed ones are
// replaced, missing ones added, absent ones removed. Actors without a Name are
// never touched. Props of types the file does not describe (custom, Raw_Draw) are left alone.
// Collider is removed when absent only if previous (the definition the world was built from)
// gave it to that actor, so code-added ones survive. Stage follows the file when it has one;
// when previous had one and this file does not, the stage is reset. Code-set stage survives.
// String lifetime: after this call no Prop points into the previous arena.
// Equal Props are overwritten with the new value, so their borrowed strings
// move to the new arena; replaced Props drop the old value; Name is cloned.
world_apply_scene :: proc(world: ^World, def: ^Scene_Def, previous: ^Scene_Def) -> bool {
	assets_load(world, def.assets)
	if stage, ok := def.stage.?; ok {
		world.stage = stage_from_def(stage)
	} else if previous != nil {
		_, had := previous.stage.?
		if had do world.stage = {}
	}
	wanted := scene_wanted(def)
	for id in world_actors(world) {
		name := actor_props(world, id, Name)
		if name != nil && name.value not_in wanted do world_destroy_actor(world, id)
	}
	for key, want in wanted {
		if id, found := world_find_by_name(world, key); found {
			sync_actor(world, id, want, previously_defined(previous, key))
		} else {
			spawn(world, ..want)
		}
	}
	return true
}

// Name key -> Props. A duplicate name is logged and dropped (first wins).
@(private = "file")
scene_wanted :: proc(def: ^Scene_Def) -> map[string][]any {
	wanted := make(map[string][]any, context.temp_allocator)
	if camera, ok := def.camera.?; ok do wanted[CAMERA_NAME] = camera_components(camera)
	for actor, index in def.actors {
		key := actor_key(actor, index)
		if key in wanted {
			log.errorf("scene %q: duplicate actor name %q, keeping the first", def.name, key)
			continue
		}
		wanted[key] = actor_props_list(actor, key)
	}
	return wanted
}

// Which optional Props the previous definition gave one actor.
@(private = "file")
Defined_Props :: struct {
	collider: bool,
}

@(private = "file")
previously_defined :: proc(previous: ^Scene_Def, key: string) -> (defined: Defined_Props) {
	if previous == nil do return
	for actor, index in previous.actors {
		if actor_key(actor, index) != key do continue
		_, defined.collider = actor.collider.?
		return
	}
	return
}

@(private = "file")
sync_actor :: proc(world: ^World, id: Actor_Id, want: []any, defined: Defined_Props) {
	carry_runtime(world, id, want)
	// Model before Animator: an Animator plays on the model it is resolved against.
	sync_kind(world, id, want, Transform)
	sync_kind(world, id, want, Model)
	sync_kind(world, id, want, Animator)
	sync_kind(world, id, want, Sprite)
	sync_kind(world, id, want, Sprite_Anim)
	sync_kind(world, id, want, Health)
	sync_kind(world, id, want, Collider, defined.collider)
	sync_kind(world, id, want, Camera)
	sync_kind(world, id, want, Camera_2D)
}

// Runtime state the file does not hold: animation time, and the frame it drives.
// Copied into the wanted value so an unchanged animation is not restarted.
@(private = "file")
carry_runtime :: proc(world: ^World, id: Actor_Id, want: []any) {
	if anim := want_prop(want, Sprite_Anim); anim != nil {
		if cur := actor_props(world, id, Sprite_Anim); cur != nil do anim.time = cur.time
	}
	if sprite := want_prop(want, Sprite); sprite != nil && want_prop(want, Sprite_Anim) != nil {
		if cur := actor_props(world, id, Sprite); cur != nil do sprite.frame = cur.frame
	}
}

// owned false keeps an absent Prop: the file did not define it, so code may own it.
@(private = "file")
sync_kind :: proc(world: ^World, id: Actor_Id, want: []any, $T: typeid, owned := true) {
	value, wanted := find_prop(want, T)
	cur := actor_props(world, id, T)
	switch {
	case !wanted:
		if cur != nil && owned do actor_remove_props(world, id, T)
	case cur != nil && cur^ == value:
		cur^ = value // same data: keep the renderable, re-point strings into the new arena
	case:
		actor_add_props(world, id, value)
	}
}

// Pointer into the wanted list's box for type T; nil when absent.
@(private = "file")
want_prop :: proc(list: []any, $T: typeid) -> ^T {
	for prop in list do if prop.id == typeid_of(T) do return (^T)(prop.data)
	return nil
}

@(private = "file")
find_prop :: proc(list: []any, $T: typeid) -> (T, bool) {
	if value := want_prop(list, T); value != nil do return value^, true
	return {}, false
}
