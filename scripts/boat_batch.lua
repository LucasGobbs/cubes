-- Batch replica of the benchmark boat (see boat.lua; constants from src/scenes/benchmark/scene.odin).
-- Per-boat state lives in module-level double arrays keyed by Actor index, grown on demand.
-- One module clock (advanced once per tick_all) drives every boat's wave phase.
local ffi = require("ffi")
local engine = require("engine")
local sea = require("sea_wave")

local M = {}
M.batch = true

local FLEE_RADIUS = 40 -- FLEE_RADIUS
local FLEE_TURN_RATE = 1.5 -- FLEE_TURN_RATE, rad/s
local SAIL_X_LIMIT = 700 -- SAIL_X_LIMIT
local SAIL_Z_NEAR = -20 -- SAIL_Z_NEAR
local SAIL_Z_FAR = -650 -- SAIL_Z_FAR
local BOAT_DRAFT = 0.1 -- BOAT_DRAFT

local PI = math.pi
local TAU = 2 * math.pi
local sin, cos, atan2, sqrt = math.sin, math.cos, math.atan2, math.sqrt
local DOUBLE = ffi.sizeof("double")

local cap = 0
local xs, zs, headings, speeds, scales = nil, nil, nil, nil, nil
local clock = 0
local sailing = true

local function grow(arr, used, new_cap)
  local new = ffi.new("double[?]", new_cap)
  if arr ~= nil then ffi.copy(new, arr, used * DOUBLE) end
  return new
end

local function reserve(n)
  if n <= cap then return end
  local new_cap = math.max(64, cap * 2, n)
  xs = grow(xs, cap, new_cap)
  zs = grow(zs, cap, new_cap)
  headings = grow(headings, cap, new_cap)
  speeds = grow(speeds, cap, new_cap)
  scales = grow(scales, cap, new_cap)
  cap = new_cap
end

function M.create(self, a)
  local k = a.index
  reserve(k + 1)
  local t = a:transform()
  xs[k] = t.position.x
  zs[k] = t.position.z
  scales[k] = t.scale.x
  headings[k] = 2 * atan2(t.rotation.y, t.rotation.w) -- pure yaw quaternion, see boat.lua
  speeds[k] = 2 + 4 * math.random() -- Odin float32_range(2, 6)
end

-- Hot reload swaps the module, so its arrays are empty: rebuild each live boat from its transform.
M.reload = M.create

function M.tick_all(ids, count, dt)
  if engine.input.pressed("benchmark.sail") then sailing = not sailing end
  clock = clock + dt
  local cam = engine.camera_position()
  local cx, cy, cz = cam[0], cam[1], cam[2]

  for i = 0, count - 1 do
    local a = ids[i]
    local k = a.index
    local x, z, heading = xs[k], zs[k], headings[k]

    if sailing then
      local dx, dz = x - cx, z - cz
      local speed = speeds[k]
      if dx * dx + dz * dz < FLEE_RADIUS * FLEE_RADIUS then
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
      xs[k], zs[k], headings[k] = x, z, heading
    end
  end

  for i = 0, count - 1 do
    local a = ids[i]
    local k = a.index
    local x, z, heading = xs[k], zs[k], headings[k]
    local dx, dy, dz = x - cx, sea.Y - cy, z - cz
    local h, gx, gz = sea.height(x, z, clock, sqrt(dx * dx + dy * dy + dz * dz))

    local t = a:transform()
    t.position.x = x
    t.position.y = sea.Y + h + BOAT_DRAFT
    t.position.z = z
    sea.set_rotation(t.rotation, gx, gz, heading)
    local s = scales[k]
    t.scale.x, t.scale.y, t.scale.z = s, s, s
  end
end

return M
