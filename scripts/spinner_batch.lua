-- Batch version of spinner.lua: same motion, one tick_all call per frame instead of one pcall per actor.
local M = {}
M.batch = true

-- Per-actor state keyed by Actor index. yaw and t advance together, so one clock t is enough.
local state = {}

function M.create(self, a)
  state[a.index] = { t = 0, base_y = a:transform().position.y }
end

function M.destroy(self, a)
  state[a.index] = nil
end

function M.tick_all(ids, count, dt)
  for i = 0, count - 1 do
    local a = ids[i]
    local s = state[a.index]
    local t = a:transform()
    s.t = s.t + dt
    t.position.y = s.base_y + math.sin(s.t * 2) * 0.25
    t.rotation.x = 0
    t.rotation.y = math.sin(s.t * 0.5)
    t.rotation.z = 0
    t.rotation.w = math.cos(s.t * 0.5)
  end
end

return M
