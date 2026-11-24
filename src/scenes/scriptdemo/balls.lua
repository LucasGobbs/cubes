-- Balls: dynamic spheres dropped onto the static ground. A touch flashes the sphere (scale up, then back).
-- Batch module: tick_all restores scales and draws the HUD once per frame. Visual only: colliders keep radius 0.5.
local engine = require("engine")

local M = {}
M.batch = true

local BASE_SCALE = 0.5 -- matches SCRIPTDEMO_BALL_SCALE in scene.odin; sphere.glb spans -1..1
local FLASH_SCALE = 0.8
local FLASH_TIME = 0.15 -- seconds

-- Per-actor flash time left, keyed by Actor index.
local flash = {}
local contacts = 0

function M.create(self, a)
  a:add_sphere_collider(0.5)
  flash[a.index] = 0
end

function M.destroy(self, a)
  flash[a.index] = nil
end

function M.on_contact(self, a, other)
  contacts = contacts + 1
  a:set_scale(FLASH_SCALE, FLASH_SCALE, FLASH_SCALE)
  flash[a.index] = FLASH_TIME
end

function M.tick_all(ids, count, dt)
  for i = 0, count - 1 do
    local a = ids[i]
    local left = flash[a.index]
    if left > 0 then
      left = left - dt
      if left <= 0 then
        left = 0
        a:set_scale(BASE_SCALE, BASE_SCALE, BASE_SCALE)
      end
      flash[a.index] = left
    end
  end
  engine.hud_text(string.format("time %.1f s", engine.time()), 10, 10)
  engine.hud_text(string.format("contacts %d", contacts), 10, 40)
end

return M
