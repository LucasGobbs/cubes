// Window atlas: a 512x512 texture of 64x64 windows, 8x8 px each. Each window is
// lit or dark by a PCG hash of (window x, window y, seed). A 1 px black border
// surrounds every window, so the glass area is the 6x6 interior.
//
// Per window (all from the hash, deterministic): lit or dark (about 50%), a warm
// base tint, a brightness (lit: 0.55..1.0; dark: 0..15% spill), a fade from the
// top row (100%) to the bottom row (60%), and up to 3 dark furniture patches in
// the lower half. Per pixel: independent colour noise and a little grey noise.
// The window shape (uniform `shape`) masks the same 6x6 interior for every window.
//
// SDL_GPU binding order for compute: uniforms -> read-write storage textures.

static const uint WINDOWS_PER_SIDE = 64;
static const uint WINDOW_PX = 8;
static const uint BORDER_PX = 1;
static const uint GLASS_PX = 6; // interior, inside the border
static const float INV_U32 = 1.0 / 4294967296.0;

// Padded to 16 bytes: push uniform data is read as one vec4.
struct WindowParams {
    uint seed;
    uint shape;
    uint pad1;
    uint pad2;
};

[[vk::binding(0, 0)]]
cbuffer UniformBlock {
    WindowParams params;
}

[[vk::binding(1, 0)]]
RWTexture2D<float4> output_image;

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

// Window shapes, 6x6 interior ('#' glass, '.' black). Row 0 is the top.
//
// 0 full        1 wide strip   2 narrow tall   3 two panes   4 rounded
// ######        ......         .####.          ##..##        .####.
// ######        ......         .####.          ##..##        ######
// ######        ######         .####.          ##..##        ######
// ######        ######         .####.          ##..##        ######
// ######        ######         .####.          ##..##        ######
// ######        ......         .####.          ##..##        .####.
//
// 5 arched      6 low strip    7 three panes
// ..##..        ......         #.#.#.
// .####.        ######         #.#.#.
// ######        ######         #.#.#.
// ######        ......         #.#.#.
// ######        ......         #.#.#.
// ######        ......         #.#.#.
bool glass(uint shape, uint x, uint y) {
    switch (shape) {
        case 1: return y >= 2 && y <= 4;
        case 2: return x >= 1 && x <= 4;
        case 3: return x <= 1 || x >= 4;
        case 4: return !((x == 0 || x == 5) && (y == 0 || y == 5));
        case 5: return (y == 0) ? (x >= 2 && x <= 3) : (y == 1) ? (x >= 1 && x <= 4) : true;
        case 6: return y == 1 || y == 2;
        case 7: return x % 2 == 0;
        default: return true;
    }
}

// Furniture: each patch is a row in the bottom 3 interior rows (3..5), a start column,
// a width of 1..3 px and a darkness of 30..80%. Returns the pixel's multiplier.
float furniture_factor(uint window_hash, uint x, uint y) {
    uint s = window_hash;
    float chance = next_rand(s);
    float count_r = next_rand(s);
    uint count = 1 + uint(count_r * 3.0);
    float factor = 1.0;
    for (uint k = 0; k < 3; k++) {
        float row_r = next_rand(s);
        float x_r = next_rand(s);
        float w_r = next_rand(s);
        float dark_r = next_rand(s);
        if (chance >= 0.6 || k >= count) continue;
        uint row = 3 + min(uint(row_r * 3.0), 2u);
        uint x0 = min(uint(x_r * 6.0), 5u);
        uint w = 1 + min(uint(w_r * 3.0), 2u);
        if (y == row && x >= x0 && x < x0 + w) factor *= 1.0 - (0.3 + 0.5 * dark_r);
    }
    return factor;
}

[shader("compute")]
[numthreads(8, 8, 1)]
void computeMain(uint2 tid : SV_DispatchThreadID)
{
    uint2 window = tid / WINDOW_PX;
    uint2 local = tid % WINDOW_PX;

    uint h = pcg(pcg(window.x ^ (window.y << 16)) + params.seed);
    bool border = min(local.x, local.y) < BORDER_PX || max(local.x, local.y) >= WINDOW_PX - BORDER_PX;
    if (border) {
        output_image[tid] = float4(0.0, 0.0, 0.0, 1.0);
        return;
    }

    uint x = local.x - BORDER_PX;
    uint y = local.y - BORDER_PX;
    if (!glass(params.shape, x, y)) {
        output_image[tid] = float4(0.0, 0.0, 0.0, 1.0);
        return;
    }

    // Window-level values: a separate chain from the lit bit, so lit stays ~50%.
    uint s = h;
    bool lit = h < 0x80000000u;
    float bright = lerp(0.55, 1.0, next_rand(s));
    float tint = next_rand(s);
    float spill = next_rand(s) * 0.15;
    float level = lit ? bright : spill;
    float3 base = lerp(float3(1.0, 0.95, 0.8), float3(1.0, 0.85, 0.55), tint);

    float fade = lerp(1.0, 0.6, float(y) / float(GLASS_PX - 1));
    float3 color = base * level * fade * furniture_factor(h ^ 0xA5A5A5A5u, x, y);

    // Per-pixel noise: +-10% per channel, plus +-3% grey.
    uint p = pcg(pcg(tid.x ^ (tid.y << 16)) + params.seed);
    float3 channel_noise = float3(
        float(pcg(p + 1u)) * INV_U32,
        float(pcg(p + 2u)) * INV_U32,
        float(pcg(p + 3u)) * INV_U32);
    float grey_noise = float(pcg(p + 4u)) * INV_U32;
    color *= 1.0 + (channel_noise * 2.0 - 1.0) * 0.10;
    color += (grey_noise * 2.0 - 1.0) * 0.03;

    output_image[tid] = float4(saturate(color), 1.0);
}
