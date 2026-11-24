-- Engine API for scripts. Loaded once per World by script_host.odin as a chunk taking
-- (api pointer, layout table, host pointer); the returned module is package.loaded.engine.
local ffi = require("ffi")
local api_ptr, layout, host_ptr = ...

ffi.cdef[[
typedef struct { float x, y, z; } Vec3;
typedef struct { float x, y, z, w; } Quat;
typedef struct { Vec3 position; Quat rotation; Vec3 scale; } Transform;
typedef struct { uint32_t index, generation; } Actor;
typedef struct {
  uint32_t version;
  bool (*actor_valid)(void *host, uint32_t index, uint32_t generation);
  Transform *(*actor_transform)(void *host, uint32_t index, uint32_t generation);
  void (*actor_destroy)(void *host, uint32_t index, uint32_t generation);
  void (*actor_find)(void *host, const char *name, Actor *out);
  void *(*actor_prop)(void *host, uint32_t index, uint32_t generation, const char *name);
  void (*spawn_model)(void *host, const char *path, float x, float y, float z, Actor *out);
  int32_t (*input_button)(void *host, const char *name);
  bool (*input_down)(void *host, int32_t action);
  bool (*input_pressed)(void *host, int32_t action);
  void (*mouse)(void *host, float *out);
  void (*hud_text)(void *host, const char *text, float x, float y);
  void (*log)(void *host, int32_t level, const char *msg);
  void (*camera_position)(void *host, float *out);
  void (*actor_set_scale)(void *host, uint32_t index, uint32_t generation, float sx, float sy, float sz);
  void (*actor_add_box_collider)(void *host, uint32_t index, uint32_t generation, float hx, float hy, float hz, bool is_static);
  void (*actor_add_sphere_collider)(void *host, uint32_t index, uint32_t generation, float radius);
  void (*actor_set_name)(void *host, uint32_t index, uint32_t generation, const char *name);
  bool (*camera_look_at)(void *host, float x, float y, float z);
  bool (*camera_set_fov)(void *host, float fov_y);
  bool (*set_fog)(void *host, float r, float g, float b, float distance);
  bool (*clear_fog)(void *host);
  bool (*set_sun)(void *host, float x, float y, float z);
  bool (*set_shadows)(void *host, bool on);
  void (*hud_text_color)(void *host, const char *text, float x, float y, float r, float g, float b, float a);
  void (*window_size)(void *host, float *out);
  float (*scene_time)(void *host);
} ScriptAPI;
]]

-- Odin computes layout; a mismatch means the cdefs above drifted from the Odin structs.
local function expect(key, actual)
  local want = layout[key]
  if want == nil then error("engine.lua: no layout entry " .. key, 0) end
  if actual ~= want then
    error(string.format("engine.lua: layout mismatch %s: LuaJIT %d, Odin %d", key, actual, want), 0)
  end
end

expect("Vec3", ffi.sizeof("Vec3"))
expect("Quat", ffi.sizeof("Quat"))
expect("Transform", ffi.sizeof("Transform"))
for _, f in ipairs({ "position", "rotation", "scale" }) do
  expect("Transform." .. f, ffi.offsetof("Transform", f))
end
expect("Actor", ffi.sizeof("Actor"))
expect("ScriptAPI", ffi.sizeof("ScriptAPI"))
for _, f in ipairs({ "version", "actor_valid", "actor_transform", "actor_destroy", "actor_find", "actor_prop",
                     "spawn_model", "input_button", "input_down", "input_pressed", "mouse",
                     "hud_text", "log", "camera_position",
                     "actor_set_scale", "actor_add_box_collider", "actor_add_sphere_collider", "actor_set_name",
                     "camera_look_at", "camera_set_fov", "set_fog", "clear_fog", "set_sun", "set_shadows",
                     "hud_text_color", "window_size", "scene_time" }) do
  expect("ScriptAPI." .. f, ffi.offsetof("ScriptAPI", f))
end

local api = ffi.cast("ScriptAPI*", api_ptr)
local host = ffi.cast("void*", host_ptr) -- this World's Script_Host; every api call takes it first
if api.version ~= 1 then
  error("engine.lua: ScriptAPI version " .. tostring(api.version) .. ", expected 1", 0)
end

-- Typed pointer type per exposed name, cast once.
local prop_types = {}
-- Actor handles: a:valid(), a:transform() (nil when stale), a:destroy() (no-op when stale).
ffi.metatype("Actor", {
  __index = {
    valid = function(a) return api.actor_valid(host, a.index, a.generation) end,
    transform = function(a) return api.actor_transform(host, a.index, a.generation) end,
    destroy = function(a) api.actor_destroy(host, a.index, a.generation) end,
    prop = function(a, name)
      local p = api.actor_prop(host, a.index, a.generation, name)
      if p == nil then return nil end
      local t = prop_types[name]
      if t == nil then
        t = ffi.typeof(name .. "*")
        prop_types[name] = t
      end
      return ffi.cast(t, p)
    end,
    set_scale = function(a, x, y, z) api.actor_set_scale(host, a.index, a.generation, x, y, z) end,
    add_box_collider = function(a, hx, hy, hz, is_static)
      api.actor_add_box_collider(host, a.index, a.generation, hx, hy, hz, is_static and true or false)
    end,
    add_sphere_collider = function(a, radius) api.actor_add_sphere_collider(host, a.index, a.generation, radius) end,
    set_name = function(a, name) api.actor_set_name(host, a.index, a.generation, name) end,
  },
})

local M = {}

-- Scene constants pushed by script_set_config. Plain numbers, read once at script load (copy into locals).
M.config = {}

-- Called by script_expose: defines the C struct and checks its size against Odin's size_of.
function M._expose(cdef_src, name, odin_size)
  ffi.cdef(cdef_src)
  local got = ffi.sizeof(name)
  if got ~= odin_size then
    error(string.format("engine.lua: exposed %s: LuaJIT %d bytes, Odin %d", name, got, odin_size), 0)
  end
end

-- Returns the Actor named name, or nil. Odin zeroes out before writing, so one reused out-param is enough.
local ActorT = ffi.typeof("Actor")
local out_actor = ffi.new(ActorT)
function M.find(name)
  api.actor_find(host, name, out_actor)
  if out_actor.generation == 0 then return nil end
  return ffi.new(ActorT, out_actor)
end

function M.spawn_model(path, x, y, z)
  api.spawn_model(host, path, x, y, z, out_actor)
  return ffi.new(ActorT, out_actor)
end

-- Action name -> index cache. Misses are not cached: the action may be registered later.
local actions = {}

local function action_index(name)
  local i = actions[name]
  if i == nil then
    i = api.input_button(host, name)
    if i >= 0 then actions[name] = i end
  end
  return i
end

M.input = {}

function M.input.down(name)
  local i = action_index(name)
  return i >= 0 and api.input_down(host, i)
end

function M.input.pressed(name)
  local i = action_index(name)
  return i >= 0 and api.input_pressed(host, i)
end

-- Reused buffer: the returned float[2] cdata is overwritten by the next M.mouse() call.
local mouse_out = ffi.new("float[2]")

function M.mouse()
  api.mouse(host, mouse_out)
  return mouse_out
end

-- Reused buffer: the returned float[3] cdata is overwritten by the next M.camera_position() call.
local camera_out = ffi.new("float[3]")

function M.camera_position()
  api.camera_position(host, camera_out)
  return camera_out
end

-- hud_text(text, x, y) draws white; hud_text(text, x, y, r, g, b[, a]) takes an sRGB colour, a defaults to 1.
function M.hud_text(text, x, y, r, g, b, a)
  if r == nil then
    api.hud_text(host, text, x, y)
  else
    api.hud_text_color(host, text, x, y, r, g, b, a or 1)
  end
end

-- Camera and environment setters act on the first live actor with that component; false when there is none.
function M.camera_look_at(x, y, z) return api.camera_look_at(host, x, y, z) end
function M.camera_set_fov(fov_y) return api.camera_set_fov(host, fov_y) end
function M.set_fog(r, g, b, distance) return api.set_fog(host, r, g, b, distance) end
function M.clear_fog() return api.clear_fog(host) end
function M.set_sun(x, y, z) return api.set_sun(host, x, y, z) end
function M.set_shadows(on) return api.set_shadows(host, on and true or false) end

-- Scene clock in seconds (World.time), a plain number.
function M.time() return api.scene_time(host) end

-- Reused buffer: the returned float[2] cdata is overwritten by the next M.window_size() call. Zeros with no Device.
local window_out = ffi.new("float[2]")

function M.window_size()
  api.window_size(host, window_out)
  return window_out
end

-- level: 0 debug, 1 info, 2 warn, anything else error.
function M.log(level, msg)
  api.log(host, level, msg)
end

-- Wraps a batch hook. Odin passes the ids buffer address as a number (lightuserdata casts NYI in traces);
-- the Actor* cast is cached by address, so steady frames allocate no cdata.
function M._batch(fn)
  local last_p, last_ids
  return function(p, count, dt)
    if p ~= last_p then
      last_p, last_ids = p, ffi.cast("Actor*", p)
    end
    fn(last_ids, count, dt)
  end
end

return M
