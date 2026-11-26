// Light sprites: round HDR glows, one camera-facing billboard per light, shared by the city's streetlights, cars and
// beacons. The vertex colour.rg carries the corner in [-1,1]^2; sprite_corner_world expands it around the light centre
// in the plane facing the eye, with a minimum on-screen size. sprite_shade is the fragment: bright core plus gaussian
// halo, discarded outside the unit disc. Drawn additively with no depth write (gfx.light_sprite_pipeline_create).

// World position of one corner of a billboard centred on `center`. width = full width in units; it grows with
// distance (min_angular per unit) so far lights stay visible.
float3 sprite_corner_world(float3 center, float2 corner, float width, float min_angular, float3 eye) {
    float3 to_eye = eye - center;
    float dist = length(to_eye);
    float3 fwd = to_eye / max(dist, 1e-4);
    float3 right = normalize(cross(float3(0.0, 1.0, 0.0), fwd));
    float3 up = cross(fwd, right);
    float size = max(width, dist * min_angular) * 0.5;
    return center + (right * corner.x + up * corner.y) * size;
}

// Fragment: core + halo in HDR, rgb = color * glow.
float4 sprite_shade(float2 corner, float3 color, float core_gain, float halo_gain) {
    float r = length(corner);
    if (r > 1.0) discard;
    float a = exp(-r * r * 4.0);
    float core = smoothstep(0.35, 0.0, r);
    return float4(color * (core * core_gain + a * halo_gain), 1.0);
}

// Blink brightness in [0.1, 1]: on for about a third of each period, dim otherwise.
float blink(float time, float phase, float period) {
    float p = frac(time / period + phase);
    float on = smoothstep(0.0, 0.06, p) * (1.0 - smoothstep(0.28, 0.35, p));
    return lerp(0.1, 1.0, on);
}
