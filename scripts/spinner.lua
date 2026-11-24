-- Bobs its actor up and down and spins it around Y. Uses only a:transform() and math.
local engine = require("engine")
local M = {}

function M.create(self, a)
  self.t = 0
  self.yaw = 0
  self.base_y = a:transform().position.y
end

function M.tick(self, a, dt)
  local t = a:transform()
  self.t = self.t + dt
  self.yaw = self.yaw + dt
  t.position.y = self.base_y + math.sin(self.t * 2) * 0.25
  t.rotation.x = 0
  t.rotation.y = math.sin(self.yaw * 0.5)
  t.rotation.z = 0
  t.rotation.w = math.cos(self.yaw * 0.5)
end

return M
