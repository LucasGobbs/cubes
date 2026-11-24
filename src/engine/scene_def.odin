// Scene definitions: a JSON file describes a scene's name, camera and the
// actors spawned at load. Example (src/scenes/postfx/scene.json):
//   { "name": "Postfx",
//     "camera": { "position": [0,1,1.9], "look_at": [0,0.8,0], "bloom": {"threshold":0.5,"intensity":1.5,"radius":12} },
//     "actors": [ { "name": "hero", "model": "static/models/rigged_cesiumman.glb", "clip": "clip_0" } ] }
// Omitted fields are zero, which the World reads as defaults (scale 1, idactor rotation).
// rotation is Euler degrees (x, y, z). Strings live in the Scene_File arena, which
// must outlive the actors (Model.path is borrowed).
package engine

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:math/linalg"
import "core:mem/virtual"
import "core:os"
import "particles"

// Name of the camera actor in the World. The file's camera is keyed by it.
CAMERA_NAME :: "__camera"

Bloom_Def :: struct {
	threshold, intensity: f32,
	radius:               i32,
}

Camera_Def :: struct {
	position:      [3]f32 `json:"position,omitempty"`,
	look_at:       Maybe([3]f32) `json:"look_at,omitempty"`,
	fov_y:         f32 `json:"fov_y,omitempty"`,
	bloom:         Maybe(Bloom_Def) `json:"bloom,omitempty"`,
	blur:          Maybe(i32) `json:"blur,omitempty"`,
	mode:          string `json:"mode,omitempty"`, // "3d" (default) or "2d": Camera_2D, position.xy is the view centre
	zoom:          f32 `json:"zoom,omitempty"`,
	viewport:      [2]f32 `json:"viewport,omitempty"`,
	integer_scale: bool `json:"integer_scale,omitempty"`,
}

Health_Def :: struct {
	current, max: f32,
}

// Props the file can describe. Raw_Draw and user-registered Props are code-only.
Actor_Def :: struct {
	name:           string `json:"name,omitempty"`,
	model:          string `json:"model,omitempty"`,
	clip:           string `json:"clip,omitempty"`,
	position:       [3]f32 `json:"position,omitempty"`,
	rotation:       [3]f32 `json:"rotation,omitempty"`, // degrees
	scale:          [3]f32 `json:"scale,omitempty"`,
	sprite:         string `json:"sprite,omitempty"`, // texture path; makes a Sprite
	grid:           [2]i32 `json:"grid,omitempty"`, // columns, rows of the sheet; {0,0} = whole image
	frame:          i32 `json:"frame,omitempty"`,
	color:          [4]f32 `json:"color,omitempty"`, // {0,0,0,0} = white
	layer:          i32 `json:"layer,omitempty"`,
	flip_x:         bool `json:"flip_x,omitempty"`,
	flip_y:         bool `json:"flip_y,omitempty"`,
	anim:           Maybe(Sprite_Anim_Def) `json:"anim,omitempty"`,
	health:         Maybe(Health_Def) `json:"health,omitempty"`,
	particles:      Maybe(particles.Emitter_Desc) `json:"particles,omitempty"`,
	collider:       Maybe(Collider_Def) `json:"collider,omitempty"`,
	environment:    Maybe(Environment_Def) `json:"environment,omitempty"`,
}

Sprite_Anim_Def :: struct {
	first, last: i32,
	fps:         f32,
	loop:        bool,
}

// Collider: physics body at the actor's Transform. shape "box" (half) or "sphere" (radius);
// body "dynamic" (default) or "static" (box only); density 0 => 1.
Collider_Def :: struct {
	shape:   string `json:"shape,omitempty"`,
	half:    [3]f32 `json:"half,omitempty"`,
	radius:  f32 `json:"radius,omitempty"`,
	body:    string `json:"body,omitempty"`,
	density: f32 `json:"density,omitempty"`,
}

Fog_Def :: struct {
	color:    [3]f32 `json:"color,omitempty"`,
	distance: f32 `json:"distance,omitempty"`,
}

// skybox: equirectangular path, loaded by update_sky while this Environment drives the renderer (not in assets).
Environment_Def :: struct {
	skybox:        string `json:"skybox,omitempty"`,
	fog:           Maybe(Fog_Def) `json:"fog,omitempty"`,
	shadows:       Maybe(bool) `json:"shadows,omitempty"`,
	sun_direction: Maybe([3]f32) `json:"sun_direction,omitempty"`,
	uncapped:      bool `json:"uncapped,omitempty"`,
}

// Everything the scene needs resident; assets_load loads it in one go.
Assets_Def :: struct {
	models:   []string `json:"models,omitempty"`, // .glb/.gltf, static or skinned (detected)
	textures: []string `json:"textures,omitempty"`, // png/jpg, sRGB
}

Scene_Def :: struct {
	name:        string `json:"name,omitempty"`,
	assets:      Assets_Def `json:"assets,omitempty"`,
	camera:      Maybe(Camera_Def) `json:"camera,omitempty"`,
	actors:    []Actor_Def `json:"actors,omitempty"`,
	clear_color: Maybe([3]f32) `json:"clear_color,omitempty"`, // sRGB background; the renderer default when omitted
}

Scene_File :: struct {
	arena: virtual.Arena,
	def:   Scene_Def,
}

Scene_File_Status :: enum {
	Ok,
	Missing, // the file does not exist; the caller decides whether that is an error (no log here)
	Invalid, // unreadable, bad JSON or an invalid definition; logged here with the detail
}

scene_file_load :: proc(file: ^Scene_File, path: string) -> Scene_File_Status {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		if err == .Not_Exist do return .Missing
		log.errorf("scene file %q: cannot read: %v", path, err)
		return .Invalid
	}
	if virtual.arena_init_growing(&file.arena) != nil {
		log.errorf("scene file %q: cannot allocate", path)
		return .Invalid
	}
	if json_err := json.unmarshal(data, &file.def, allocator = virtual.arena_allocator(&file.arena)); json_err != nil {
		log.errorf("scene file %q: %v", path, json_err)
		virtual.arena_destroy(&file.arena)
		return .Invalid
	}
	if problem := scene_def_problem(&file.def); problem != "" {
		log.errorf("scene file %q: %s", path, problem)
		virtual.arena_destroy(&file.arena)
		return .Invalid
	}
	return .Ok
}

scene_file_destroy :: proc(file: ^Scene_File) {
	virtual.arena_destroy(&file.arena)
	file^ = {}
}

// Key an actor is matched by: its name, or "#<index>" when it has none.
actor_key :: proc(actor: Actor_Def, index: int) -> string {
	if actor.name != "" do return actor.name
	return fmt.tprintf("#%d", index)
}

// Applies the definition to an (usually empty) world and returns the actor ids
// in definition order (camera excluded). A duplicate name gets the id of the
// first actor with that name. The slice uses the temp allocator.
world_spawn_scene :: proc(world: ^World, def: ^Scene_Def) -> []Actor_Id {
	world_apply_scene(world, def, nil)
	ids := make([]Actor_Id, len(def.actors), context.temp_allocator)
	for actor, index in def.actors do ids[index], _ = world_find_by_name(world, actor_key(actor, index))
	return ids
}

// Transform of a definition: zero fields get the World defaults, so the result
// compares equal to the live Transform.
@(private)
def_transform :: proc(position, rotation, scale: [3]f32) -> Transform {
	transform := Transform{position = position, rotation = linalg.QUATERNIONF32_IDENTITY, scale = {1, 1, 1}}
	if scale != {} do transform.scale = scale
	if rotation != {} {
		r := rotation * linalg.RAD_PER_DEG
		transform.rotation = linalg.quaternion_from_euler_angles_f32(r.x, r.y, r.z, .XYZ)
	}
	return transform
}

// Boxes a Prop on the temp allocator so its any outlives the building proc.
@(private)
prop_box :: proc(value: $T) -> any {
	box := new(T, context.temp_allocator)
	box^ = value
	return any{data = box, id = typeid_of(T)}
}

// Props of one definition actor, Name first.
@(private)
actor_props_list :: proc(actor: Actor_Def, key: string) -> []any {
	list := make([dynamic]any, context.temp_allocator)
	append(&list, prop_box(Name{key}), prop_box(def_transform(actor.position, actor.rotation, actor.scale)))
	if actor.model != "" do append(&list, prop_box(Model{path = actor.model}))
	if actor.clip != "" do append(&list, prop_box(Animator{clip = actor.clip}))
	if actor.sprite != "" {
		append(&list, prop_box(Sprite{texture = actor.sprite, grid = actor.grid, frame = actor.frame, color = actor.color, layer = actor.layer, flip_x = actor.flip_x, flip_y = actor.flip_y}))
		if anim, has := actor.anim.?; has do append(&list, prop_box(Sprite_Anim{first = anim.first, last = anim.last, fps = anim.fps, loop = anim.loop}))
	}
	if health, has := actor.health.?; has do append(&list, prop_box(Health{current = health.current, max = health.max}))
	if emitter, has := actor.particles.?; has {
		emitter.position = {} // World overrides from Transform
		append(&list, prop_box(Particle_Emitter(emitter)))
	}
	if collider, has := actor.collider.?; has do append(&list, prop_box(collider_from_def(collider)))
	if environment, has := actor.environment.?; has do append(&list, prop_box(environment_from_def(environment)))
	return list[:]
}

// Props of the camera actor, Name first; mode picks Camera_2D or Camera.
@(private)
camera_components :: proc(camera: Camera_Def) -> []any {
	list := make([dynamic]any, context.temp_allocator)
	append(&list, prop_box(Name{CAMERA_NAME}), prop_box(def_transform(camera.position, {}, {})))
	if camera.mode == "2d" {
		append(&list, prop_box(Camera_2D{zoom = camera.zoom, viewport = camera.viewport, integer_scale = camera.integer_scale}))
		return list[:]
	}
	if camera.mode != "" && camera.mode != "3d" do log.errorf("scene: unknown camera mode %q", camera.mode)
	c := Camera{fov_y = camera.fov_y, blur = camera.blur}
	if look_at, has := camera.look_at.?; has do c.look_at = Vec3(look_at)
	if bloom, has := camera.bloom.?; has do c.bloom = Bloom{bloom.threshold, bloom.intensity, bloom.radius}
	append(&list, prop_box(c))
	return list[:]
}

// Checks what the parser cannot: shape and body names, fields that belong to the other shape.
// Returns "" when valid, else the problem; scene_file_load names the file.
scene_def_problem :: proc(def: ^Scene_Def) -> string {
	for actor, index in def.actors {
		collider, has := actor.collider.?
		if !has do continue
		if problem := collider_def_problem(collider); problem != "" do return fmt.tprintf("actor %q collider: %s", actor_key(actor, index), problem)
	}
	return ""
}

@(private)
collider_def_problem :: proc(c: Collider_Def) -> string {
	switch c.body {
	case "", "dynamic", "static":
	case:
		return fmt.tprintf("body %q: want \"dynamic\" or \"static\"", c.body)
	}
	if c.density < 0 do return "density must not be negative"
	switch c.shape {
	case "box":
		if c.radius != 0 do return "box takes half, not radius"
		if c.half.x <= 0 || c.half.y <= 0 || c.half.z <= 0 do return "box half must be > 0 on every axis"
	case "sphere":
		if c.half != {} do return "sphere takes radius, not half"
		if c.radius <= 0 do return "sphere radius must be > 0"
		if c.body == "static" do return "static sphere is not supported: use a box"
	case:
		return fmt.tprintf("shape %q: want \"box\" or \"sphere\"", c.shape)
	}
	return ""
}

// Props of the definitions; the collider and environment are read by the World at spawn and on reload.
@(private)
collider_from_def :: proc(def: Collider_Def) -> Collider {
	collider := Collider{density = def.density}
	if def.body == "static" {
		collider.body = .Static
	}
	if def.shape == "box" {
		collider.shape = Box{half = def.half}
	} else {
		collider.shape = Sphere{radius = def.radius}
	}
	return collider
}

@(private)
environment_from_def :: proc(def: Environment_Def) -> Environment {
	env := Environment{skybox = def.skybox, shadows = def.shadows, sun_direction = def.sun_direction, uncapped = def.uncapped}
	if fog, has := def.fog.?; has {
		env.fog = Fog{fog.color, fog.distance}
	}
	return env
}
