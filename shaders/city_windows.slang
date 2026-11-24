// Window atlas: 6x6 tiles of 512x512 texels (3072 x 3072). Each tile is 64x64 windows of 8 px, each window a 1 px
// black border around a 6x6 glass interior. A tile's look comes from a hash of (seed, tile index): its lit ratio,
// its room size (windows per lit or dark room, rooms aligned to the tile grid with a per-tile offset; office tiles
// use full-width rooms, so whole floors light up), its window shape (one of 10 glass masks), its lamp colour
// (warm, neutral, cool or rare green-white) and its curtain style (none, blinds, mullions or a cross).
//
// Lighting per window: its room is lit with probability lit_ratio. A window in a lit room is off with 8% chance,
// a window in a dark room is on with 3% chance. Lit windows then get the detail below.
//
// Per window (all from the hash, deterministic): a brightness (lit: 0.55..1.0; dark: 0..15% spill), a lamp tint
// (lamp colour, 0.9..1.0 of it), 8% of lit windows are a flat TV blue, a fade from the top row (100%) to the
// bottom row (60%), up to 3 dark furniture patches in the lower half, and for blinds a dark row at a random height.
// Per pixel: independent colour noise and a little grey noise.
//
// SDL_GPU binding order for compute: uniforms -> read-write storage textures.

static const uint TILE_COUNT_SIDE = 6; // must match TILE_COUNT_SIDE in window_texture.odin
static const uint TILE_PX = 512;
static const uint TILE_WINDOWS = 64; // windows per tile side
static const uint WINDOW_PX = 8;
static const uint BORDER_PX = 1;
static const uint GLASS_PX = 6; // interior, inside the border
static const float INV_U32 = 1.0 / 4294967296.0;

// Padded to 16 bytes: push uniform data is read as one vec4.
struct WindowParams {
    uint seed;
    uint pad1;
    uint pad2;
    uint pad3;
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
// 5 arched      6 low strip    7 three panes  8 double-hung  9 porthole
// ..##..        ......         #.#.#.         ######         ..##..
// .####.        ######         #.#.#.         ######         .####.
// ######        ######         #.#.#.         ......         ######
// ######        ......         #.#.#.         ######         ######
// ######        ......         #.#.#.         ######         .####.
// ######        ......         #.#.#.         ######         ..##..
bool porthole(uint x, uint y) {
    int dx = abs(2 * int(x) - 5);
    int dy = abs(2 * int(y) - 5);
    return dx * dx + dy * dy <= 26;
}

bool glass(uint shape, uint x, uint y) {
    switch (shape) {
        case 1: return y >= 2 && y <= 4;
        case 2: return x >= 1 && x <= 4;
        case 3: return x <= 1 || x >= 4;
        case 4: return !((x == 0 || x == 5) && (y == 0 || y == 5));
        case 5: return (y == 0) ? (x >= 2 && x <= 3) : (y == 1) ? (x >= 1 && x <= 4) : true;
        case 6: return y == 1 || y == 2;
        case 7: return x % 2 == 0;
        case 8: return y != 2;
        case 9: return porthole(x, y);
        default: return true;
    }
}

// Lamp colour per tile: 0 warm, 1 neutral, 2 cool, 3 green-white (rare).
float3 lamp_colour(uint k) {
    switch (k) {
        case 0: return float3(1.0, 0.82, 0.5);
        case 1: return float3(1.0, 0.95, 0.82);
        case 2: return float3(0.78, 0.9, 1.0);
        default: return float3(0.82, 1.0, 0.86);
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

// Per-tile look. salt seeds the room hashes, so the rooms differ from tile to tile.
struct TileParams {
    uint salt;
    float lit_ratio;
    uint room_w;
    uint room_h;
    uint shape;
    uint off_x;
    uint off_y;
    uint lamp;
    uint curtain; // 0 none, 1 blinds, 2 mullions, 3 cross
};

TileParams tile_params(uint tile_index) {
    TileParams t;
    t.salt = pcg(pcg(tile_index ^ 0x7F4A7C15u) + params.seed);
    uint s = t.salt;
    t.lit_ratio = lerp(0.08, 0.9, next_rand(s));
    float office_r = next_rand(s);
    uint room_w = 1 + min(uint(next_rand(s) * 6.0), 5u);
    t.room_w = office_r < 0.3 ? 128u : room_w; // office: a room spans the full row (rooms are 64 wide at most)
    t.room_h = 1 + min(uint(next_rand(s) * 3.0), 2u);
    t.shape = min(uint(next_rand(s) * 10.0), 9u);
    t.off_x = min(uint(next_rand(s) * float(TILE_WINDOWS)), TILE_WINDOWS - 1);
    t.off_y = min(uint(next_rand(s) * float(TILE_WINDOWS)), TILE_WINDOWS - 1);
    float lamp_r = next_rand(s);
    t.lamp = lamp_r < 0.4 ? 0u : (lamp_r < 0.7 ? 1u : (lamp_r < 0.9 ? 2u : 3u));
    t.curtain = min(uint(next_rand(s) * 4.0), 3u);
    return t;
}

// Whether the room holding window (wx, wy) of the tile is lit: rooms are room_w x room_h windows on a grid
// shifted by the tile offset.
bool room_lit(TileParams t, uint wx, uint wy) {
    uint rx = (wx + t.off_x) / t.room_w;
    uint ry = (wy + t.off_y) / t.room_h;
    uint h = pcg(pcg(rx ^ (ry << 16)) + t.salt);
    return float(h) * INV_U32 < t.lit_ratio;
}

[shader("compute")]
[numthreads(8, 8, 1)]
void computeMain(uint2 tid : SV_DispatchThreadID)
{
    uint2 tile = tid / TILE_PX;
    uint tile_index = tile.y * TILE_COUNT_SIDE + tile.x;
    uint2 in_tile = tid % TILE_PX;
    uint2 window = in_tile / WINDOW_PX;
    uint2 local = in_tile % WINDOW_PX;

    TileParams t = tile_params(tile_index);
    bool border = min(local.x, local.y) < BORDER_PX || max(local.x, local.y) >= WINDOW_PX - BORDER_PX;
    if (border) {
        output_image[tid] = float4(0.0, 0.0, 0.0, 1.0);
        return;
    }

    uint x = local.x - BORDER_PX;
    uint y = local.y - BORDER_PX;
    if (!glass(t.shape, x, y)) {
        output_image[tid] = float4(0.0, 0.0, 0.0, 1.0);
        return;
    }

    // Window-level values: one hash per window, drawn in a fixed order.
    uint h = pcg(pcg(window.x | (window.y << 6) | (tile_index << 12)) + params.seed);
    uint s = h;
    float flip = next_rand(s);
    bool lit = room_lit(t, window.x, window.y) ? flip >= 0.08 : flip < 0.03;
    float bright = lerp(0.55, 1.0, next_rand(s));
    float tint = next_rand(s);
    float spill = next_rand(s) * 0.15;
    float tv_r = next_rand(s);
    float blind_r = next_rand(s);
    uint blind_row = min(uint(next_rand(s) * float(GLASS_PX)), GLASS_PX - 1);
    float level = lit ? bright : spill;
    float3 base = (lit && tv_r < 0.08) ? float3(0.5, 0.66, 1.0) : lamp_colour(t.lamp) * lerp(0.9, 1.0, tint);

    float fade = lerp(1.0, 0.6, float(y) / float(GLASS_PX - 1));
    float blinds = (t.curtain == 1 && lit && blind_r < 0.5 && y == blind_row) ? 0.2 : 1.0;
    bool wide = t.shape == 0 || t.shape == 1 || t.shape == 4 || t.shape == 6;
    float mullion = (t.curtain == 2 && wide && x == 2) ? 0.35 : 1.0;
    float cross_bar = (t.curtain == 3 && (x == 2 || y == 2)) ? 0.35 : 1.0;
    float3 color = base * level * fade * furniture_factor(h ^ 0xA5A5A5A5u, x, y) * blinds * mullion * cross_bar;

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
