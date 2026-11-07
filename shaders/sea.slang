// Toon sea: a flat quad whose waves are evaluated per pixel from a sum of
// deep-water sine waves. Wave normals drive hard-edged light bands, crest and
// glint highlights, and a horizon rim. Each wave fades with distance relative
// to its own wavelength so short waves don't alias into noise at range.

struct Uniforms {
    float4x4 mvp;
    float4x4 model;
    float4 camera_position;
    float4 time; // x = seconds
    float4 fog; // rgb = linear fog color, a = view distance (<= 0 = off)
};

[[vk::binding(0, 0)]]
cbuffer UniformBlock {
    Uniforms data;
}

struct VertexInput {
    [[vk::location(0)]] float3 position : POSITION;
};

struct VertexOutput {
    float4 position : SV_POSITION;
    float3 world : WORLD;
    float3 to_camera : TO_CAMERA;
    float time : TIME;
    float4 fog : FOG;
};


// Simplex noise (Gustavson 2D), values in about [-1, 1].
float3 mod289_3(float3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
float2 mod289_2(float2 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
float3 permute3(float3 x) { return mod289_3(((x * 34.0) + 1.0) * x); }

float simplex2(float2 v) {
    const float4 C = float4(0.211324865405187, 0.366025403784439, -0.577350269189626, 0.024390243902439);
    float2 i = floor(v + dot(v, C.yy));
    float2 x0 = v - i + dot(i, C.xx);
    float2 i1 = x0.x > x0.y ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float4 x12 = x0.xyxy + C.xxzz;
    x12.xy = x12.xy - i1;
    i = mod289_2(i);
    float3 pp = permute3(permute3(i.y + float3(0.0, i1.y, 1.0)) + i.x + float3(0.0, i1.x, 1.0));
    float3 m = max(0.5 - float3(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), 0.0);
    m = m * m;
    m = m * m;
    float3 x = 2.0 * frac(pp * C.www) - 1.0;
    float3 h = abs(x) - 0.5;
    float3 ox = floor(x + 0.5);
    float3 a0 = x - ox;
    m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);
    float3 g;
    g.x = a0.x * x0.x + h.x * x0.y;
    g.yz = a0.yz * x12.xz + h.yz * x12.yw;
    return 130.0 * dot(m, g);
}

// Swell: x = height sample, yz = slope per world unit (forward difference, so it
// matches the height). freq sets feature size; speed drifts the swell over time.
float3 swell(float2 p, float freq, float speed, float time) {
    float2 q = p * freq + float2(time * speed, 0.0);
    float s = simplex2(q);
    return float3(s, simplex2(q + float2(freq, 0.0)) - s, simplex2(q + float2(0.0, freq)) - s);
}

static const float PI = 3.14159265358979;
static const float GRAVITY = 9.81;
static const int WAVE_COUNT = 10;
static const float WAVE_STEEPNESS = 0.06; // per wave; amplitude = steepness / k

// Height of the wave field at p; grad receives its horizontal gradient.
float wave_height(float2 p, float time, float dist, int wave_count, bool fine, out float2 grad) {
    float h = 0.0;
    grad = float2(0.0, 0.0);
    float wavelength = 70.0;
    float angle = 0.3;
    for (int i = 0; i < wave_count; i++) {
        float k = 2.0 * PI / wavelength;
        float omega = sqrt(GRAVITY * k); // deep-water dispersion: short waves move faster
        float amplitude = WAVE_STEEPNESS / k;
        float2 dir = float2(cos(angle), sin(angle));
        float fade = 1.0 - smoothstep(wavelength * 80.0, wavelength * 160.0, dist);
        float phase = dot(dir, p) * k - omega * time;
        h += amplitude * sin(phase) * fade;
        grad += amplitude * k * cos(phase) * dir * fade;
        wavelength *= 0.68;
        angle += 2.39996; // golden angle: no repeating directional pattern
    }
    // Simplex swells break the regular lattice of the sine sum; faded with distance.
    float nf = 1.0 - smoothstep(300.0, 1500.0, dist);
    float3 broad = swell(p, 0.008, 0.01, time);
    h += nf * 3.0 * broad.x;
    grad += nf * 3.0 * broad.yz;
    if (fine) {
        // Shading-only detail: finer than the mesh grid can displace.
        float3 fine_swell = swell(p, 0.03, -0.02, time);
        h += nf * 1.5 * fine_swell.x;
        grad += nf * 1.5 * fine_swell.yz;
    }
    return h;
}

static const int SURFACE_WAVES = 3; // waves that displace the mesh; CPU mirror: sea_wave.odin

[shader("vertex")]
VertexOutput vertexMain(VertexInput input) {
    VertexOutput output;
    float4 flat_world = mul(data.model, float4(input.position, 1.0));
    float2 grad;
    float dist = length(data.camera_position.xyz - flat_world.xyz);
    float3 local = input.position;
    local.y += wave_height(flat_world.xz, data.time.x, dist, SURFACE_WAVES, false, grad);
    float4 world = mul(data.model, float4(local, 1.0));
    output.position = mul(data.mvp, float4(local, 1.0));
    output.world = world.xyz;
    output.to_camera = data.camera_position.xyz - world.xyz;
    output.time = data.time.x;
    float t = data.fog.a > 0.0 ? saturate((length(output.to_camera) - 0.6 * data.fog.a) / (0.4 * data.fog.a)) : 0.0;
    output.fog = float4(data.fog.rgb, t);
    return output;
}

float to_linear_channel(float c) {
    return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4);
}

// Hash for cell features: two independent values in [0, 1).
float2 hash22(float2 p) {
    p = float2(dot(p, float2(127.1, 311.7)), dot(p, float2(269.5, 183.3)));
    return frac(sin(p) * 43758.5453);
}

// Ring foam: each unit cell holds one ring in ~18% of cells, centred at a hashed
// point, radius pulsing over time. Returns coverage 0..1, anti-aliased by aa.
float ring_foam(float2 p, float time, float aa) {
    float2 cell = floor(p);
    float coverage = 0.0;
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            float2 c = cell + float2(i, j);
            float2 h = hash22(c);
            float2 center = c + 0.2 + 0.6 * hash22(c + 17.0);
            float radius = 0.14 + 0.1 * h.y + 0.03 * sin(time * 1.5 + 6.2831 * h.x);
            float d = abs(length(p - center) - radius);
            float ring = 1.0 - smoothstep(0.05 - aa, 0.05 + aa, d);
            coverage = max(coverage, ring * step(h.x, 0.18));
        }
    }
    return coverage;
}

// Slow sideways warp so the rings drift and wobble instead of sliding rigidly.
float2 flow(float2 p, float time) {
    return float2(sin(p.y * 0.6 + time * 0.7), cos(p.x * 0.5 - time * 0.5)) * 0.12;
}

[shader("fragment")]
float4 pixelMain(VertexOutput input) : SV_Target0 {
    float dist = length(input.to_camera);
    float3 v = input.to_camera / dist;

    float2 grad;
    float h = wave_height(input.world.xz, input.time, dist, WAVE_COUNT, true, grad);
    float3 n = normalize(float3(-grad.x, 1.0, -grad.y));

    // sRGB palette: flat Wind Waker blue body, pale band on lit slopes, white ring foam.
    float3 body = float3(0.11, 0.48, 0.82);
    float3 light = float3(0.27, 0.64, 0.90);
    float3 dark = float3(0.08, 0.38, 0.71);
    float3 foam = float3(0.95, 0.98, 1.0);
    float3 sky = float3(0.671, 0.757, 0.949); // skybox horizon; keep equal to the fog color in benchmark_scene.odin

    // Same sun as the boats' Phong light. A flat sea has ndl = sun.y = 0.811.
    float3 sun = float3(0.3244, 0.8111, 0.4867);
    float ndl = dot(n, sun);
    float3 color = ndl > 0.83 ? light : body;

    // Large slow noise patches tint the water between deep blue and teal.
    float patch = smoothstep(0.25, 0.75, 0.5 + 0.5 * simplex2(input.world.xz * 0.012 + input.time * 0.01));
    float3 tint = lerp(float3(0.06, 0.30, 0.72), float3(0.12, 0.62, 0.78), patch);
    color = lerp(color, color * tint / body, 0.7);

    // Fresnel: grazing views reflect the sky, so a low camera sees blue, not flat white.
    float ndv = saturate(dot(n, v));
    color = lerp(color, sky, pow(1.0 - ndv, 3.0) * 0.7);

    // Foam fades to flat color with distance, where it would alias into noise.
    float foam_fade = 1.0 - smoothstep(80.0, 220.0, dist);

    // Ring foam in flow-warped world space (5-unit cells): faint dark rings under white rings.
    float2 p = input.world.xz * 0.2;
    float aa = max(fwidth(p.x), fwidth(p.y));
    float2 q = p + flow(p, input.time);
    color = lerp(color, dark, 0.3 * foam_fade * ring_foam(q + 0.5, input.time * 0.8, aa));
    color = lerp(color, foam, foam_fade * ring_foam(q, input.time, aa));

    // Crest foam on steep slopes.
    color = lerp(color, foam, foam_fade * smoothstep(0.45, 0.55, length(grad)));

    // Always blend into the sky at range, independent of the fog toggle.
    color = lerp(color, sky, smoothstep(60.0, 900.0, dist));

    // The swapchain is SDR_LINEAR: shaders output linear color.
    float3 linear_color = float3(
        to_linear_channel(color.x),
        to_linear_channel(color.y),
        to_linear_channel(color.z));
    return float4(lerp(linear_color, input.fog.rgb, input.fog.a), 1.0);
}
