package engine

import "core:log"

// Hot reload: makes the live world match def. Entities match by Name; components
// equal by value are refreshed in place (no renderable rebuild), changed ones are
// replaced, missing ones added, absent ones removed. Entities without a Name are
// never touched.
// String lifetime: after this call no component points into the previous arena.
// Equal components are overwritten with the new value, so their borrowed strings
// move to the new arena; replaced components drop the old value; Name is cloned.
world_apply_scene :: proc(world: ^World, def: ^Scene_Def) -> bool {
	assets_load(world, def.assets)
	apply_clear_color(world, def)
	wanted := scene_wanted(def)
	for id in world_entities(world) {
		name := entity_get_component(world, id, Name)
		if name != nil && name.value not_in wanted do world_destroy_entity(world, id)
	}
	for key, want in wanted {
		if id, found := world_find_by_name(world, key); found {
			sync_entity(world, id, want)
		} else {
			spawn(world, ..want)
		}
	}
	return true
}

// Sets the renderer background from the file. No-op without a Device (tests).
apply_clear_color :: proc(world: ^World, def: ^Scene_Def) {
	if color, ok := def.clear_color.?; ok && world.gfx_ctx != nil do world.gfx_ctx.renderer.clear_color = {color.x, color.y, color.z, 1}
}

// Name key -> components. A duplicate name is logged and dropped (first wins).
@(private = "file")
scene_wanted :: proc(def: ^Scene_Def) -> map[string][]Component {
	wanted := make(map[string][]Component, context.temp_allocator)
	if camera, ok := def.camera.?; ok do wanted[CAMERA_NAME] = camera_components(camera)
	for entity, index in def.entities {
		key := entity_key(entity, index)
		if key in wanted {
			log.errorf("scene %q: duplicate entity name %q, keeping the first", def.name, key)
			continue
		}
		wanted[key] = entity_components(entity, key)
	}
	return wanted
}

@(private = "file")
sync_entity :: proc(world: ^World, id: Entity_Id, want: []Component) {
	carry_runtime(world, id, want)
	// Model before Animator: an Animator plays on the model it is resolved against.
	sync_kind(world, id, want, Transform)
	sync_kind(world, id, want, Model)
	sync_kind(world, id, want, Animator)
	sync_kind(world, id, want, Sprite)
	sync_kind(world, id, want, Sprite_Anim)
	sync_kind(world, id, want, Health)
	sync_kind(world, id, want, Camera)
	sync_kind(world, id, want, Camera_2D)
}

// Runtime state the file does not hold: animation time, and the frame it drives.
// Copied into the wanted value so an unchanged animation is not restarted.
@(private = "file")
carry_runtime :: proc(world: ^World, id: Entity_Id, want: []Component) {
	_, animated := find_component(want, Sprite_Anim)
	for &component in want {
		#partial switch &value in component {
		case Sprite_Anim:
			if cur := entity_get_component(world, id, Sprite_Anim); cur != nil do value.time = cur.time
		case Sprite:
			if cur := entity_get_component(world, id, Sprite); cur != nil && animated do value.frame = cur.frame
		}
	}
}

@(private = "file")
sync_kind :: proc(world: ^World, id: Entity_Id, want: []Component, $T: typeid) {
	value, wanted := find_component(want, T)
	cur := entity_get_component(world, id, T)
	switch {
	case !wanted:
		if cur != nil do entity_remove_component(world, id, T)
	case cur != nil && cur^ == value:
		cur^ = value // same data: keep the renderable, re-point strings into the new arena
	case:
		entity_add_component(world, id, Component(value))
	}
}

@(private = "file")
find_component :: proc(list: []Component, $T: typeid) -> (T, bool) {
	for component in list do if value, ok := component.(T); ok do return value, true
	return {}, false
}
