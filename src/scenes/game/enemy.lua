-- Enemy ship: chases the "player" actor on the XZ plane; on contact it damages the player and destroys itself.
-- Constants come from engine.config, pushed by game_create from game_enemy.odin.
local engine = require("engine")
local CFG = engine.config
local SPEED = assert(CFG.ENEMY_SPEED, "enemy.lua: ENEMY_SPEED not in engine.config")
local HIT_RADIUS = assert(CFG.ENEMY_HIT_RADIUS, "enemy.lua: ENEMY_HIT_RADIUS not in engine.config")
local HIT_DAMAGE = assert(CFG.ENEMY_HIT_DAMAGE, "enemy.lua: ENEMY_HIT_DAMAGE not in engine.config")

local M = {}

function M.tick(self, a, dt)
  if self.player == nil or not self.player:valid() then
    self.player = engine.find("player")
    if self.player == nil then return end
  end
  local pt = self.player:transform()
  if pt == nil then return end

  local t = a:transform()
  local dx, dz = pt.position.x - t.position.x, pt.position.z - t.position.z
  local len = math.sqrt(dx * dx + dz * dz)
  if len > 0 then
    local step = SPEED * dt / len
    t.position.x = t.position.x + dx * step
    t.position.z = t.position.z + dz * step
  end

  -- Yaw about Y toward the target, as game_facing: quaternion (0, sin(yaw/2), 0, cos(yaw/2)).
  local yaw = math.atan2(dx, dz)
  t.rotation.x = 0
  t.rotation.y = math.sin(yaw * 0.5)
  t.rotation.z = 0
  t.rotation.w = math.cos(yaw * 0.5)

  local ex = t.position.x - pt.position.x
  local ey = t.position.y - pt.position.y
  local ez = t.position.z - pt.position.z
  if math.sqrt(ex * ex + ey * ey + ez * ez) >= HIT_RADIUS then return end

  local hp = self.player:prop("Health")
  hp.current = hp.current - HIT_DAMAGE
  engine.log(1, string.format("game: enemy destroyed, health %.0f/%.0f", hp.current, hp.max))
  a:destroy() -- a is stale from here: return at once
  return
end

return M
