-- Per-actor replica of the benchmark boat (src/scenes/benchmark/scene.odin boat_step and the
-- sea loop in benchmark_tick). Scene constants come from engine.config (set by benchmark_lua_setup);
-- initial heading and speed come from the Boat prop. Wave phase is engine.time(), the scene clock.
local engine = require("engine")
local sea = require("src.scenes.sea.sea_wave")

local M = {}

-- A missing key is a load error: a silent nil would turn every boat into NaN.
local function config(name)
  local v = engine.config[name]
  if v == nil then error("boat.lua: engine.config." .. name .. " not set (scene must script_set_config it)", 0) end
  return v
end

local FLEE_RADIUS = config("FLEE_RADIUS")
local FLEE_TURN_RATE = config("FLEE_TURN_RATE") -- rad/s
local SAIL_X_LIMIT = config("SAIL_X_LIMIT")
local SAIL_Z_NEAR = config("SAIL_Z_NEAR")
local SAIL_Z_FAR = config("SAIL_Z_FAR")
local BOAT_DRAFT = config("BOAT_DRAFT")

local PI = math.pi
local TAU = 2 * math.pi
local sin, cos, atan2, sqrt = math.sin, math.cos, math.atan2, math.sqrt

function M.create(self, a)
  local t = a:transform()
  local boat = a:prop("Boat")
  if boat == nil then error("boat.lua: actor has no Boat prop", 0) end
  self.x = t.position.x
  self.z = t.position.z
  self.scale = t.scale.x
  self.heading = boat.heading
  self.speed = boat.speed
  self.sailing = true
end

function M.tick(self, a, dt)
  if engine.input.pressed("benchmark.sail") then self.sailing = not self.sailing end

  local cam = engine.camera_position()
  local cx, cy, cz = cam[0], cam[1], cam[2]
  local x, z, heading = self.x, self.z, self.heading

  if self.sailing then
    local dx, dz = x - cx, z - cz
    local speed = self.speed
    if dx * dx + dz * dz < FLEE_RADIUS * FLEE_RADIUS then
      -- heading h moves along (sin h, cos h), so the away direction is atan2(dx, dz)
      local diff = atan2(dx, dz) - heading
      while diff > PI do diff = diff - TAU end
      while diff < -PI do diff = diff + TAU end
      local lim = FLEE_TURN_RATE * dt
      if diff > lim then diff = lim elseif diff < -lim then diff = -lim end
      heading = heading + diff
      speed = speed * 2
    end
    x = x + sin(heading) * speed * dt
    z = z + cos(heading) * speed * dt
    if x < -SAIL_X_LIMIT then x = SAIL_X_LIMIT elseif x > SAIL_X_LIMIT then x = -SAIL_X_LIMIT end
    if z < SAIL_Z_FAR then z = SAIL_Z_NEAR elseif z > SAIL_Z_NEAR then z = SAIL_Z_FAR end
    self.x, self.z, self.heading = x, z, heading
  end

  local dx, dy, dz = x - cx, sea.Y - cy, z - cz
  local h, gx, gz = sea.height(x, z, engine.time(), sqrt(dx * dx + dy * dy + dz * dz))

  local t = a:transform()
  t.position.x = x
  t.position.y = sea.Y + h + BOAT_DRAFT
  t.position.z = z
  sea.set_rotation(t.rotation, gx, gz, heading)
  local s = self.scale
  t.scale.x, t.scale.y, t.scale.z = s, s, s
end

return M
