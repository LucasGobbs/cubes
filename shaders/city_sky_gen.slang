// Night sky: 2048 x 512 texture. u is the angle around the lampshade (tiles, so x wraps), v is height: row 0 is the
// zenith, the last row the horizon. Per pixel: a warm-to-black gradient, sparse stars, then clouds as squashed
// blobs. Clouds are dark silhouettes, lit on their underside by the horizon glow.
//
// Blobs are shared per group: 64 threads load the cloud list into groupshared memory once, so the per-pixel loop
// reads it from on-chip memory.
//
// SDL_GPU binding order for compute: uniforms -> read-write storage textures.

static const uint SKY_W = 2048;
static const uint SKY_H = 512;
static const uint CLOUD_COUNT = 160;
static const uint GROUP_SIDE = 8;
static const float INV_U32 = 1.0 / 4294967296.0;
static const float3 BLUE = float3(0.10, 0.20, 0.50);
static const float3 DARK = float3(0.02, 0.035, 0.12);
static const float3 BLACK = float3(0.0, 0.0, 0.01);

// Padded to 16 bytes: push uniform data is read as one vec4.
struct SkyParams {
    uint seed;
    uint pad1;
    uint pad2;
    uint pad3;
};

[[vk::binding(0, 0)]]
cbuffer UniformBlock {
    SkyParams params;
}

[[vk::binding(1, 0)]]
RWTexture2D<float4> output_image;

// Per cloud: x = centre u (texels), y = centre v (texels), z = base radius (texels), w = dark level.
groupshared float4 blobs[CLOUD_COUNT];

uint pcg(uint v) {
    uint state = v * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

// Next uniform in [0, 1) from a chained hash state.
float next_rand(inout uint s) {
    s = pcg(s + 0x9E3779B9u);
    return float(s) * INV_U32;
}

float3 hsv2rgb(float3 c) {
    float3 p = abs(frac(c.xxx + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
    return c.z * lerp(float3(1.0, 1.0, 1.0), saturate(p - 1.0), c.y);
}

// Horizon glow: a warm hue from red through orange to yellow or magenta, with random saturation and value.
float3 warm_colour(uint seed) {
    uint s = pcg(seed ^ 0x5EED1234u);
    float hue = frac(lerp(-0.15, 0.16, next_rand(s)));
    float sat = lerp(0.6, 0.9, next_rand(s));
    float val = lerp(0.7, 1.0, next_rand(s));
    float3 c = hsv2rgb(float3(hue, sat, val));
    float lum = dot(c, float3(0.3, 0.59, 0.11));
    return lerp(c, float3(lum, lum, lum), 0.25); // a little less saturated, so the band reads as glow not paint
}

// Height h: 0 at the zenith, 1 at the horizon.
float3 gradient(float h, float3 warm) {
    float3 c = lerp(warm, BLUE, smoothstep(0.0, 0.09, h)); // narrow warm band: lowest ~10% of the texture
    c = lerp(c, DARK, smoothstep(0.12, 0.35, h));
    return lerp(c, BLACK, smoothstep(0.35, 0.65, h));
}

// Single-texel star, or zero. Stars thin out toward the zenith.
float3 star(uint2 p, float h) {
    if (h < 0.25 || p.y < 4) return float3(0.0, 0.0, 0.0); // top rows are stretched far up the dome: a star there would be a streak
    uint s = pcg(pcg(p.x | (p.y << 11)) + params.seed);
    float chance = 0.0012 * lerp(1.0, 4.0, smoothstep(0.25, 1.0, h));
    if (next_rand(s) >= chance) return float3(0.0, 0.0, 0.0);
    float bright = lerp(0.4, 1.0, next_rand(s));
    float3 tint = float3(1.0, 1.0, 1.0);
    float kind = next_rand(s);
    if (kind < 1.0 / 12.0) {
        tint = next_rand(s) < 0.5 ? float3(0.7, 0.8, 1.0) : float3(1.0, 0.9, 0.7);
    }
    return bright * tint;
}

[shader("compute")]
[numthreads(8, 8, 1)]
void computeMain(uint2 tid : SV_DispatchThreadID, uint group_index : SV_GroupIndex)
{
    // Cooperative load: every thread of the group writes its share of the cloud list. Barrier before any use.
    for (uint i = group_index; i < CLOUD_COUNT; i += GROUP_SIDE * GROUP_SIDE) {
        uint s = pcg(pcg(i ^ 0xC10D5u) + params.seed);
        float cx = next_rand(s) * float(SKY_W);
        float cy = lerp(0.45, 0.97, sqrt(next_rand(s))) * float(SKY_H); // sqrt: more clouds near the horizon
        float r = lerp(24.0, 90.0, next_rand(s));
        float dark = 0.02 + next_rand(s) * 0.04;
        blobs[i] = float4(cx, cy, r, dark);
    }
    GroupMemoryBarrierWithGroupSync();

    float h = 1.0 - (float(tid.y) + 0.5) / float(SKY_H);
    float3 warm = warm_colour(params.seed);
    float3 sky = gradient(h, warm) + star(tid, h);

    float transmit = 1.0;
    float3 cloud_sum = float3(0.0, 0.0, 0.0);
    float weight_sum = 0.0;
    for (uint i = 0; i < CLOUD_COUNT; i++) {
        float4 b = blobs[i];
        // Minimal image: the sky wraps in u, so measure to the nearest copy of the blob.
        float dx = (float(tid.x) + 0.5) - b.x;
        if (dx > float(SKY_W) * 0.5) dx -= float(SKY_W);
        else if (dx < -float(SKY_W) * 0.5) dx += float(SKY_W);
        float ry = b.z * lerp(1.0, 0.12, b.y / float(SKY_H)); // flatter near the horizon
        float dy = (float(tid.y) + 0.5) - b.y;
        float d = length(float2(dx / b.z, dy / ry));
        if (d >= 1.0) continue;

        float a = 1.0 - smoothstep(0.0, 1.0, d);
        float w = a * 0.30;
        transmit *= 1.0 - w;
        // Underside: the bottom 30% of the blob takes the horizon glow.
        float below = saturate(dy / ry * 0.5 + 0.5);
        float lit = smoothstep(0.5, 1.0, below) * 0.9;
        float3 col = lerp(float3(b.w, b.w, b.w), warm, lit);
        cloud_sum += w * col;
        weight_sum += w;
    }

    float coverage = 1.0 - transmit;
    float3 cloud = weight_sum > 0.0 ? cloud_sum / weight_sum : float3(0.0, 0.0, 0.0);
    output_image[tid] = float4(saturate(lerp(sky, cloud, coverage)), 1.0);
}
