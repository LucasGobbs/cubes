// Day cycle and lightning: pure functions of the clock (hours, seconds) and the city seed. The night look (22 h, clear)
// is the base: daylight 0, no exposure offset, the night fog, and the night sky texture at full strength.
package city

import "core:math"
import "core:math/linalg"

DAY_CYCLE_SECONDS :: 90 // real seconds for a full day when the automatic cycle runs
DAY_START_HOUR :: 22 // the night look
DAY_EXPOSURE_EV :: -2.0 // grade offset at full daylight; the night grade is +1 EV
DAY_HORIZON :: [3]f32{0.62, 0.78, 0.95} // linear day sky at the horizon
DAY_ZENITH :: [3]f32{0.16, 0.36, 0.78} // linear day sky overhead
DUSK_HORIZON :: [3]f32{1.0, 0.42, 0.14} // linear sunrise / sunset band
DUSK_ZENITH :: [3]f32{0.36, 0.16, 0.42} // linear magenta overhead at twilight
SUN_COLOR :: [3]f32{1.0, 0.92, 0.75}
LIGHTNING_SLOT :: 8 // seconds per strike slot; strike jitter of 4 s keeps strikes 4..12 s apart
LIGHTNING_SEED_MIX :: 0x6C8E9CF5

// Sky, fog and light for one hour. Colours are linear, except fog_color: it is numeric in the same convention as
// CITY_FOG (what the shaders blend with), so at night it equals CITY_FOG.color.
Day_Params :: struct {
	daylight:      f32, // 0 night .. 1 day
	twilight:      f32, // 0 away from the horizon crossings .. 1 at sunrise / sunset: warms the ground haze near the horizon
	horizon_color: [3]f32,
	zenith_color:  [3]f32,
	fog_color:     [3]f32,
	exposure_ev:   f32, // added to the grade's exposure
	star_alpha:    f32, // visibility of the night sky texture (stars, clouds, night glow); 1 - daylight
	sun_dir:       [3]f32, // unit, y up, toward the sun
	sun_angle:     f32, // radians: 0 at 6 h, pi/2 at noon, pi at 18 h
}

// Hours wrapped into [0, 24).
wrap_hour :: proc(hour: f32) -> f32 {
	return hour - 24 * math.floor(hour / 24)
}

// Sun angle: 0 at sunrise (6 h), pi/2 at noon, pi at sunset (18 h); below the horizon from 18 h to 6 h.
sun_angle :: proc(hour: f32) -> f32 {
	return (wrap_hour(hour) - 6) / 12 * math.PI
}

smooth_step :: proc(edge0, edge1, x: f32) -> f32 {
	t := clamp((x - edge0) / (edge1 - edge0), 0, 1)
	return t * t * (3 - 2 * t)
}

sky_params :: proc(hour: f32) -> Day_Params {
	angle := sun_angle(hour)
	height := math.sin(angle)
	day := smooth_step(-0.12, 0.12, height)
	twilight := 1 - smooth_step(0, 0.35, abs(height)) // warm band around the horizon crossings
	horizon := linalg.lerp(DAY_HORIZON, DUSK_HORIZON, twilight)
	zenith := linalg.lerp(DAY_ZENITH, DUSK_ZENITH, twilight * 0.6)
	sun := linalg.normalize([3]f32{-math.cos(angle), height, 0.35})
	// Dusk fog: the saturated orange band is muted and dimmed so the haze over the city reads as dusk, not paint.
	grey := linalg.dot(horizon, [3]f32{0.2126, 0.7152, 0.0722})
	twilight_fog := linalg.lerp(horizon, [3]f32{grey, grey, grey}, 0.7) * 0.6
	return {
		daylight      = day,
		twilight      = twilight,
		horizon_color = horizon,
		zenith_color  = zenith,
		fog_color     = linalg.lerp([3]f32{0.01938, 0.023256, 0.03876}, linalg.lerp(horizon, twilight_fog, twilight), day),
		exposure_ev   = DAY_EXPOSURE_EV * day,
		star_alpha    = 1 - day,
		sun_dir       = sun,
		sun_angle     = angle,
	}
}

// Advances the clock by dt real seconds at the auto speed (24 h per DAY_CYCLE_SECONDS), wrapped into [0, 24).
day_cycle_advance :: proc(hour, dt: f32) -> f32 {
	return wrap_hour(hour + dt * 24 / DAY_CYCLE_SECONDS)
}

// Strike time of one slot: slot * LIGHTNING_SLOT plus a seeded jitter in [0, 4) s.
lightning_strike :: proc(seed: u32, slot: i32) -> f32 {
	r := rng_seed(seed ~ LIGHTNING_SEED_MIX ~ u32(slot) * 0x9E3779B9)
	rng_u32(&r) // first output of a near-zero xorshift state is weakly mixed
	return f32(slot) * LIGHTNING_SLOT + 4 * rng_f32(&r)
}

// Flash intensity in [0, 1] at time t (s): 1 at a strike, a fast spike then a slower tail (about 0.15 s in all).
lightning :: proc(t: f32, seed: u32) -> f32 {
	if t < 0 do return 0
	k := i32(t / LIGHTNING_SLOT)
	flash: f32
	for slot in k - 1 ..= k {
		if slot < 0 do continue
		dt := t - lightning_strike(seed, slot)
		if dt >= 0 do flash = max(flash, 0.6 * math.exp(-dt / 0.03) + 0.4 * math.exp(-dt / 0.12))
	}
	return min(flash, 1)
}
