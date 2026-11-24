-- Engine API for scripts. Loaded once per World by script_host.odin as a chunk taking
-- (api pointer, layout table); the returned module is package.loaded.engine.
local ffi = require("ffi")
local api_ptr, layout = ...

ffi.cdef[[
typedef struct { float x, y, z; } Vec3;
typedef struct { float x, y, z, w; } Quat;
typedef struct { Vec3 position; Quat rotation; Vec3 scale; } Transform;
typedef struct { uint32_t index, generation; } Actor;
typedef struct {
  uint32_t version;
  bool (*actor_valid)(uint32_t index, uint32_t generation);
  Transform *(*actor_transform)(uint32_t index, uint32_t generation);
  void (*actor_destroy)(uint32_t index, uint32_t generation);
  void (*actor_find)(const char *name, Actor *out);
  void *(*actor_prop)(uint32_t index, uint32_t generation, const char *name);
  void (*spawn_model)(const char *path, float x, float y, float z, Actor *out);
  int32_t (*input_button)(const char *name);
  bool (*input_down)(int32_t action);
  bool (*input_pressed)(int32_t action);
  void (*mouse)(float *out);
  void (*hud_text)(const char *text, float x, float y);
  void (*log)(int32_t level, const char *msg);
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
                     "hud_text", "log" }) do
  expect("ScriptAPI." .. f, ffi.offsetof("ScriptAPI", f))
end

local api = ffi.cast("ScriptAPI*", api_ptr)
if api.version ~= 1 then
  error("engine.lua: ScriptAPI version " .. tostring(api.version) .. ", expected 1", 0)
end

-- Typed pointer type per exposed name, cast once.
local prop_types = {}
-- Actor handles: a:valid(), a:transform() (nil when stale), a:destroy() (no-op when stale).
ffi.metatype("Actor", {
  __index = {
    valid = function(a) return api.actor_valid(a.index, a.generation) end,
    transform = function(a) return api.actor_transform(a.index, a.generation) end,
    destroy = function(a) api.actor_destroy(a.index, a.generation) end,
    prop = function(a, name)
      local p = api.actor_prop(a.index, a.generation, name)
      if p == nil then return nil end
      local t = prop_types[name]
      if t == nil then
        t = ffi.typeof(name .. "*")
        prop_types[name] = t
      end
      return ffi.cast(t, p)
    end,
  },
})

local M = {}

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
  api.actor_find(name, out_actor)
  if out_actor.generation == 0 then return nil end
  return ffi.new(ActorT, out_actor)
end

function M.spawn_model(path, x, y, z)
  api.spawn_model(path, x, y, z, out_actor)
  return ffi.new(ActorT, out_actor)
end

-- Action name -> index cache. Misses are not cached: the action may be registered later.
local actions = {}

local function action_index(name)
  local i = actions[name]
  if i == nil then
    i = api.input_button(name)
    if i >= 0 then actions[name] = i end
  end
  return i
end

M.input = {}

function M.input.down(name)
  local i = action_index(name)
  return i >= 0 and api.input_down(i)
end

function M.input.pressed(name)
  local i = action_index(name)
  return i >= 0 and api.input_pressed(i)
end

-- Reused buffer: the returned float[2] cdata is overwritten by the next M.mouse() call.
local mouse_out = ffi.new("float[2]")

function M.mouse()
  api.mouse(mouse_out)
  return mouse_out
end

function M.hud_text(text, x, y)
  api.hud_text(text, x, y)
end

-- level: 0 debug, 1 info, 2 warn, anything else error.
function M.log(level, msg)
  api.log(level, msg)
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
