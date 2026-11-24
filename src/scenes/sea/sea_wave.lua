-- Lua port of src/scenes/sea/sea_wave.odin (surface_height) and sea.odin (tilt, yaw).
local floor, sin, cos, sqrt, acos = math.floor, math.sin, math.cos, math.sqrt, math.acos
local max, PI = math.max, math.pi

local M = {}
M.Y = -0.6

-- Simplex constants: the Odin literals (f32 there, double here).
local C0 = 0.211324865405187
local C1 = 0.366025403784439
local C2 = -0.577350269189626
local C3 = 0.024390243902439
local INV289 = 1.0 / 289.0

local function mod289(x)
  return x - floor(x * INV289) * 289.0
end

local function permute(x)
  return mod289((x * 34.0 + 1.0) * x)
end

-- Falloff m^4 of one simplex corner, from its squared distance d2.
local function falloff(d2)
  local t = max(0.5 - d2, 0)
  t = t * t
  return t * t
end

-- One simplex corner: falloff m4, permutation pp, gradient (gx, gy). Returns m * g.
local function corner(pp, m4, gx, gy)
  local fr = pp * C3
  local x = 2.0 * (fr - floor(fr)) - 1.0
  local h = (x < 0 and -x or x) - 0.5
  local a0 = x - floor(x + 0.5)
  return m4 * (1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h)) * (a0 * gx + h * gy)
end

-- Gustavson 2D simplex, values in about [-1, 1]. Mirrors sea_simplex2.
local function simplex2(vx, vy)
  local d = (vx + vy) * C1
  local ix = floor(vx + d)
  local iy = floor(vy + d)
  local s = (ix + iy) * C0
  local x0x = vx - ix + s
  local x0y = vy - iy + s
  local i1x, i1y = 0.0, 1.0
  if x0x > x0y then i1x, i1y = 1.0, 0.0 end
  local x1x = x0x + C0 - i1x
  local x1y = x0y + C0 - i1y
  local x2x = x0x + C2
  local x2y = x0y + C2
  ix = mod289(ix)
  iy = mod289(iy)
  local ya0 = permute(iy)
  local ya1 = permute(iy + i1y)
  local ya2 = permute(iy + 1.0)
  local p0 = permute(ya0 + ix)
  local p1 = permute(ya1 + ix + i1x)
  local p2 = permute(ya2 + ix + 1.0)
  local r = corner(p0, falloff(x0x * x0x + x0y * x0y), x0x, x0y)
    + corner(p1, falloff(x1x * x1x + x1y * x1y), x1x, x1y)
    + corner(p2, falloff(x2x * x2x + x2y * x2y), x2x, x2y)
  return 130.0 * r
end

-- Returns height s and forward differences in x and y, as sea_swell.
local function swell(px, py, freq, speed, time)
  local qx = px * freq + time * speed
  local qy = py * freq
  local s = simplex2(qx, qy)
  return s, simplex2(qx + freq, qy) - s, simplex2(qx, qy + freq) - s
end

local function smoothstep(e0, e1, x)
  local t = (x - e0) / (e1 - e0)
  if t < 0 then t = 0 elseif t > 1 then t = 1 end
  return t * t * (3 - 2 * t)
end

-- Per-wave constants of surface_height, computed once in the same order as the Odin loop.
local WAVE_K, WAVE_OMEGA, WAVE_AMP, WAVE_DX, WAVE_DY, WAVE_FADE0, WAVE_FADE1 = {}, {}, {}, {}, {}, {}, {}
do
  local wavelength, angle = 70.0, 0.3
  for i = 1, 3 do
    local k = 2 * PI / wavelength
    WAVE_K[i] = k
    WAVE_OMEGA[i] = sqrt(9.81 * k)
    WAVE_AMP[i] = 0.06 / k
    WAVE_DX[i] = cos(angle)
    WAVE_DY[i] = sin(angle)
    WAVE_FADE0[i] = wavelength * 80
    WAVE_FADE1[i] = wavelength * 160
    wavelength = wavelength * 0.68
    angle = angle + 2.39996
  end
end

-- Surface height and horizontal gradient at (x, z); dist is camera distance. Returns h, gx, gz.
-- Sine waves and broad swell only: the part the mesh displaces (see wave_height in sea.slang).
function M.height(x, z, time, dist)
  local h, gx, gz = 0.0, 0.0, 0.0
  for i = 1, 3 do
    local fade = 1 - smoothstep(WAVE_FADE0[i], WAVE_FADE1[i], dist)
    local phase = (WAVE_DX[i] * x + WAVE_DY[i] * z) * WAVE_K[i] - WAVE_OMEGA[i] * time
    h = h + WAVE_AMP[i] * sin(phase) * fade
    local g = WAVE_AMP[i] * WAVE_K[i] * cos(phase) * fade
    gx = gx + g * WAVE_DX[i]
    gz = gz + g * WAVE_DY[i]
  end
  local nf = 1 - smoothstep(300, 1500, dist)
  local s, sx, sy = swell(x, z, 0.008, 0.01, time)
  h = h + nf * 3.0 * s
  gx = gx + nf * 3.0 * sx
  gz = gz + nf * 3.0 * sy
  return h, gx, gz
end

-- Writes into Quat cdata q: tilt(grad) * yaw(heading), as sea.odin tilt and quaternion_from_euler_angles(0, heading, 0).
-- tilt rotates up onto normalize(-gx, 1, -gz) about axis (-gz, 0, gx)/|(gx, gz)|, angle acos(ny).
function M.set_rotation(q, gx, gz, heading)
  local ny = 1 / sqrt(gx * gx + 1 + gz * gz) -- normal.y; |normal| >= 1 so acos stays in range
  local hl = sqrt(gx * gx + gz * gz)
  local ax, az = 0.0, 0.0
  if hl > 0 then
    ax = -gz / hl
    az = gx / hl
  end
  local half = acos(ny) * 0.5
  local s = sin(half)
  local tx, tz, tw = ax * s, az * s, cos(half)
  -- yaw = (0, sin(h/2), 0, cos(h/2)); Hamilton product tilt * yaw with ty = 0
  local hs = sin(heading * 0.5)
  local hc = cos(heading * 0.5)
  q.x = tx * hc - tz * hs
  q.y = tw * hs
  q.z = tx * hs + tz * hc
  q.w = tw * hc
end

return M
