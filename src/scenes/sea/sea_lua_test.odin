package sea

// Parity: src/scenes/sea/sea_wave.lua against the Odin surface_height and tilt * yaw, on the same samples.
// Run from the repo root (make test-engine does): the script host resolves require("src.scenes.sea.sea_wave") cwd-relative.

import "core:c"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:strings"
import "core:testing"
import engine "../../engine"
import luajit "../../engine/luajit"

SEA_PARITY_SAMPLES :: 200
SEA_PARITY_STRIDE :: 7 // per sample: h, gx, gz, qx, qy, qz, qw
SEA_PARITY_TOLERANCE :: 1e-3 // scaled by max(1, |want|)

// Lua side builds the same grid with the same integer formulas (see sea_parity_lua below).
Sea_Parity_Sample :: struct {
	x, z, time, dist, heading: f32,
}

// Every input is a small dyadic rational or an integer, so f32 (Odin) and double (Lua) see identical values.
sea_parity_sample :: proc(i: int) -> Sea_Parity_Sample {
	dist: f32
	switch i % 4 {
	case 0: dist = f32(i % 50) / 2 // 0..24.5: near camera, all fades ~1
	case 1: dist = 300 + f32((i * 13) % 1500) // 300..1800: swell fade and sine fade edges
	case 2: dist = 5600 + f32((i * 7) % 5600) // 5600..11200: wave 0 fade range
	case: dist = 11200 + f32((i * 29) % 9000) // past every fade end
	}
	return {
		x       = f32((i * 37) % 401 - 200) / 4, // -50..50, negative included
		z       = f32((i * 91) % 397 - 198) / 8,
		time    = f32(i % 17) / 4,
		dist    = dist,
		heading = f32((i % 23) - 11) / 8,
	}
}

sea_parity_lua :: `
local ffi = require("ffi")
local engine = require("engine") -- loads the Quat cdef
local sea = require("src.scenes.sea.sea_wave")
local q = ffi.new("Quat")
parity = {}
parity_y = sea.Y
for i = 0, 199 do
  local x = ((i * 37) % 401 - 200) / 4
  local z = ((i * 91) % 397 - 198) / 8
  local time = (i % 17) / 4
  local dist
  local k = i % 4
  if k == 0 then dist = (i % 50) / 2
  elseif k == 1 then dist = 300 + (i * 13) % 1500
  elseif k == 2 then dist = 5600 + (i * 7) % 5600
  else dist = 11200 + (i * 29) % 9000 end
  local heading = ((i % 23) - 11) / 8
  local h, gx, gz = sea.height(x, z, time, dist)
  sea.set_rotation(q, gx, gz, heading)
  local o = i * 7
  parity[o + 1] = h
  parity[o + 2] = gx
  parity[o + 3] = gz
  parity[o + 4] = q.x
  parity[o + 5] = q.y
  parity[o + 6] = q.z
  parity[o + 7] = q.w
end
`

// Reads parity[index] (1-based) from the global table on top of the stack.
@(private = "file")
sea_parity_read :: proc(L: ^luajit.State, index: int) -> f64 {
	luajit.rawgeti(L, -1, c.int(index))
	defer luajit.pop(L)
	return luajit.tonumber(L, -1)
}

@(test)
sea_wave_lua_matches_odin :: proc(t: ^testing.T) {
	world := engine.world_create(nil)
	defer engine.world_destroy(&world)
	L := engine.script_host_get(&world).L

	src := strings.clone_to_cstring(sea_parity_lua, context.temp_allocator)
	if !testing.expect_value(t, luajit.loadstring(L, src), luajit.LUA_OK) {
		testing.expectf(t, false, "sea_wave.lua load: %s", luajit.tostring(L, -1))
		return
	}
	if !testing.expect_value(t, luajit.pcall(L, 0, 0, 0), luajit.LUA_OK) {
		testing.expectf(t, false, "sea_wave.lua run: %s", luajit.tostring(L, -1))
		return
	}

	luajit.getglobal(L, "parity_y")
	testing.expect_value(t, luajit.tonumber(L, -1), f64(Y))
	luajit.pop(L)

	luajit.getglobal(L, "parity")
	defer luajit.pop(L)

	max_abs, max_scaled: f64
	worst: int = -1
	for i in 0 ..< SEA_PARITY_SAMPLES {
		s := sea_parity_sample(i)
		h, grad := surface_height({s.x, s.z}, s.time, s.dist)
		yaw := linalg.quaternion_from_euler_angles(f32(0), s.heading, f32(0), .XYZ)
		q := tilt(grad) * yaw
		want := [SEA_PARITY_STRIDE]f64{
			f64(h),
			f64(grad.x),
			f64(grad.y),
			f64(q.x),
			f64(q.y),
			f64(q.z),
			f64(q.w),
		}
		for k in 0 ..< SEA_PARITY_STRIDE {
			got := sea_parity_read(L, i * SEA_PARITY_STRIDE + k + 1)
			abs_err := math.abs(got - want[k])
			scaled := abs_err / max(1, math.abs(want[k]))
			if abs_err > max_abs do max_abs = abs_err
			if scaled > max_scaled {
				max_scaled = scaled
				worst = i * SEA_PARITY_STRIDE + k
			}
		}
	}
	fmt.printfln("sea_wave parity: %d samples, max abs err %g, max scaled err %g (tol %g), worst index %d", SEA_PARITY_SAMPLES, max_abs, max_scaled, SEA_PARITY_TOLERANCE, worst)
	testing.expectf(t, max_scaled <= SEA_PARITY_TOLERANCE, "scaled error %g > %g at flat index %d", max_scaled, SEA_PARITY_TOLERANCE, worst)
}
