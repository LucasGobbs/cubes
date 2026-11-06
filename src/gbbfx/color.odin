package gbbfx

import "core:math"

// The swapchain and scene color are *_SRGB: shaders compute in linear space and
// the hardware encodes on write. Colors written as numbers in code or by an
// artist-facing UI ({0.2, 0.2, 0.5}) are display (sRGB) values, so convert
// them before they reach a clear color, a uniform or a vertex color. glTF
// baseColorFactor is already linear by spec and must NOT go through this.

srgb_to_linear :: proc(c: f32) -> f32 {
	if c <= 0.04045 do return c / 12.92
	return math.pow((c + 0.055) / 1.055, 2.4)
}

// Alpha is already linear coverage and is left untouched.
color_srgb_to_linear :: proc(c: [4]f32) -> [4]f32 {
	return {srgb_to_linear(c.r), srgb_to_linear(c.g), srgb_to_linear(c.b), c.a}
}

// Mip chain length down to 1x1: floor(log2(max(w, h))) + 1.
mip_level_count :: proc(width, height: u32) -> u32 {
	levels: u32 = 1
	for size := max(width, height); size > 1; size >>= 1 do levels += 1
	return levels
}
