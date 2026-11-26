package city

import "core:math"
import "core:testing"

@(test)
test_sky_params_continuous_and_periodic :: proc(t: ^testing.T) {
	a := sky_params(0)
	b := sky_params(24)
	testing.expectf(t, math.abs(a.daylight - b.daylight) < 1e-5 && a.sun_dir == b.sun_dir, "hour 0 and 24 differ")
	testing.expectf(t, a.fog_color == b.fog_color && a.horizon_color == b.horizon_color, "colours at 0 and 24 differ")

	prev := sky_params(0)
	for i in 1 ..= 2400 {
		p := sky_params(f32(i) * 0.01)
		jump := max(math.abs(p.daylight - prev.daylight), math.abs(p.exposure_ev - prev.exposure_ev) / 2, math.abs(p.sun_dir.y - prev.sun_dir.y))
		testing.expectf(t, jump < 0.02, "jump %v at hour %v", jump, f32(i) * 0.01)
		prev = p
	}
}

@(test)
test_full_night_21_to_4 :: proc(t: ^testing.T) {
	for h := f32(21); h <= 28; h += 0.25 { // 28 = 4 h after midnight
		p := sky_params(h)
		testing.expectf(t, p.daylight == 0 && p.exposure_ev == 0 && p.star_alpha == 1, "hour %v not full night", h)
		testing.expectf(t, p.fog_color == CITY_FOG.color, "hour %v: fog is not the night fog", h)
	}
}

@(test)
test_sunrise_noon_sunset :: proc(t: ^testing.T) {
	testing.expectf(t, sky_params(5).daylight < 0.01, "5 h should still be night")
	testing.expectf(t, math.abs(sky_params(6).daylight - 0.5) < 0.05, "6 h should be half daylight")
	testing.expectf(t, sky_params(12).daylight == 1, "noon should be full day")
	testing.expectf(t, math.abs(sky_params(18).daylight - 0.5) < 0.05, "18 h should be half daylight")
	testing.expectf(t, sky_params(19).daylight < 0.01, "19 h should be night")
}

@(test)
test_sun_angle_and_direction :: proc(t: ^testing.T) {
	testing.expectf(t, math.abs(sun_angle(6)) < 1e-5, "sun angle at 6 h")
	testing.expectf(t, math.abs(sun_angle(12) - math.PI / 2) < 1e-5, "sun angle at noon")
	testing.expectf(t, math.abs(sun_angle(18) - math.PI) < 1e-5, "sun angle at 18 h")
	testing.expectf(t, sky_params(12).sun_dir.y > 0.9, "sun should be high at noon")
	testing.expectf(t, sky_params(0).sun_dir.y < 0, "sun should be below the horizon at midnight")
	testing.expectf(t, sky_params(22).sun_dir.y < 0, "sun should be below the horizon at 22 h")
}

@(test)
test_wrap_and_day_cycle_advance :: proc(t: ^testing.T) {
	testing.expectf(t, wrap_hour(-1) == 23 && wrap_hour(25) == 1, "wrap_hour")
	// 90 real seconds is one full day: 22 h + 90 s wraps back to 22 h.
	testing.expectf(t, math.abs(day_cycle_advance(22, DAY_CYCLE_SECONDS) - 22) < 1e-3, "full day should return to the start hour")
	testing.expectf(t, math.abs(day_cycle_advance(22, 1) - (22 + 24.0 / DAY_CYCLE_SECONDS)) < 1e-4, "one second advances 24/90 h")
}

@(test)
test_lightning_deterministic_bounded_and_spaced :: proc(t: ^testing.T) {
	seed := u32(7)
	for i in 0 ..< 4000 {
		time := f32(i) * 0.05
		a := lightning(time, seed)
		testing.expectf(t, a == lightning(time, seed), "lightning differs between calls at %v", time)
		testing.expectf(t, a >= 0 && a <= 1, "lightning %v out of [0,1] at %v", a, time)
	}
	testing.expectf(t, lightning(-1, seed) == 0, "no flash before t = 0")

	for slot in i32(0) ..< 200 {
		gap := lightning_strike(seed, slot + 1) - lightning_strike(seed, slot)
		testing.expectf(t, gap > 4 && gap < 12, "slot %d: gap %v outside 4..12 s", slot, gap)
		s := lightning_strike(seed, slot)
		testing.expectf(t, lightning(s, seed) == 1, "slot %d: no full flash at its strike", slot)
		testing.expectf(t, lightning(s + 1, seed) < 0.01, "slot %d: flash still on after 1 s", slot)
	}
}
