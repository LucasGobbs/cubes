// Window atlas: 6x6 tiles of 512x512 texels (3072 x 3072). Each tile is 64x64 cells of 8 px. A tile's look comes
// from a hash of (seed, tile index).
//
// Tile layouts (t.layout, one per tile):
//   0 grid     standard 8 px windows: 1 px black border, 6x6 glass in one of 10 shapes, rooms, curtains.
//   1 ribbon   continuous horizontal glazing: black only on the top and bottom row of each cell, plus a 1 px
//              mullion at the left edge of every 4th cell. Rooms are 8 or 16 cells wide, so strips light up together.
//   2 punched  4x4 glass centred in each 8 px cell, a 2 px dark wall round it.
//   3 curtain  fully glazed grid with 1 px dark lines; each floor (row) has its own brightness, 0.45..1.0.
//
// Tile-wide masks, applied to every window in the tile:
//   gain       dim 0.5 (25% of tiles), normal 0.75..1.0, bright 1.0..1.2 (25%). Neon ignores it.
//   stairwell  (25% of tiles) one column every 5..9 windows is always lit (a stair core).
//   neon band  (1 tile in 6) the bottom 3 window rows (y < 3) glow magenta or violet on 80% of windows.
//
// Per window, from the hash (deterministic):
//   room       the room holding it is lit with probability lit_ratio; lit windows are off with 8% chance, dark
//              windows on with 3%.
//   brightness lit: 0.7..1.0; dark: 0..5% spill (dark windows read near black).
//   office     2% of lit windows are white (flat 1.0), not lamp-tinted.
//   half lit   10% of lit windows: a diagonal split, pixels with x + y <= k lit, the rest in spill.
//   TV         8% of lit windows: flat TV blue.
//   fade       from the top row (100%) to the bottom row (60%).
//   furniture  up to 3 dark patches in the lower interior rows.
//   blinds     (grid, curtain style 1) one dark row at a random height.
// Per pixel: independent +-10% channel noise and +-3% grey noise.
//
// SDL_GPU binding order for compute: uniforms -> read-write storage textures.

import constants;

static const uint BORDER_PX = 1;
static const uint GLASS_PX = 6; // interior, inside the border
static const float INV_U32 = 1.0 / 4294967296.0;

static const uint LAYOUT_GRID = 0;
static const uint LAYOUT_RIBBON = 1;
static const uint LAYOUT_PUNCHED = 2;
static const uint LAYOUT_CURTAIN = 3;

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

// Grid window shapes, 6x6 interior ('#' glass, '.' black). Row 0 is the top.
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
bool porthole(int x, int y) {
    int dx = abs(2 * x - 5);
    int dy = abs(2 * y - 5);
    return dx * dx + dy * dy <= 26;
}

bool glass(uint shape, int x, int y) {
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

float3 neon_colour(uint k) {
    return k == 1u ? float3(1.0, 0.22, 0.8) : float3(0.62, 0.3, 1.0);
}

// Furniture: each patch is a row in the bottom 3 interior rows (3..5), a start column,
// a width of 1..3 px and a darkness of 30..80%. Returns the pixel's multiplier.
float furniture_factor(uint window_hash, int x, int y) {
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
        int row = 3 + int(min(uint(row_r * 3.0), 2u));
        int x0 = int(min(uint(x_r * 6.0), 5u));
        int w = 1 + int(min(uint(w_r * 3.0), 2u));
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
    uint layout;  // LAYOUT_*
    float gain;   // tile brightness
    uint stair;   // 0 none, else column period 5..9
    uint stair_off;
    uint neon;    // 0 none, 1 magenta, 2 violet
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

    float layout_r = next_rand(s);
    t.layout = layout_r < 0.4 ? LAYOUT_GRID : (layout_r < 0.6 ? LAYOUT_RIBBON : (layout_r < 0.8 ? LAYOUT_PUNCHED : LAYOUT_CURTAIN));
    float ribbon_r = next_rand(s);
    if (t.layout == LAYOUT_RIBBON) t.room_w = ribbon_r < 0.5 ? 8u : 16u;

    float gain_r = next_rand(s);
    float gain_mid = next_rand(s);
    t.gain = gain_r < 0.25 ? 0.5 : (gain_r > 0.75 ? lerp(1.0, 1.2, gain_mid) : lerp(0.75, 1.0, gain_mid));

    float stair_r = next_rand(s);
    float stair_period_r = next_rand(s);
    float stair_off_r = next_rand(s);
    t.stair = stair_r < 0.25 ? 5u + min(uint(stair_period_r * 5.0), 4u) : 0u;
    t.stair_off = t.stair > 0u ? min(uint(stair_off_r * float(t.stair)), t.stair - 1u) : 0u;

    float neon_r = next_rand(s);
    float neon_kind_r = next_rand(s);
    t.neon = neon_r < 1.0 / 6.0 ? 1u + min(uint(neon_kind_r * 2.0), 1u) : 0u;
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

    // Glass test. Interior coords x, y are signed: ribbon glass reaches the outer cell columns.
    int x = int(local.x) - int(BORDER_PX);
    int y = int(local.y) - int(BORDER_PX);
    bool is_glass;
    if (t.layout == LAYOUT_RIBBON) {
        is_glass = y >= 0 && y <= 5 && !(x == -1 && window.x % 4u == 0u);
    } else if (t.layout == LAYOUT_PUNCHED) {
        is_glass = x >= 1 && x <= 4 && y >= 1 && y <= 4;
    } else {
        bool inside = min(local.x, local.y) >= BORDER_PX && max(local.x, local.y) < WINDOW_PX - BORDER_PX;
        is_glass = inside && glass(t.layout == LAYOUT_CURTAIN ? 0u : t.shape, x, y);
    }
    if (!is_glass) {
        output_image[tid] = float4(0.0, 0.0, 0.0, 1.0);
        return;
    }

    // Window-level values: one hash per window, drawn in a fixed order.
    uint h = pcg(pcg(window.x | (window.y << 6) | (tile_index << 12)) + params.seed);
    uint s = h;
    float flip = next_rand(s);
    bool lit = room_lit(t, window.x, window.y) ? flip >= 0.08 : flip < 0.03;
    float bright = lerp(0.7, 1.0, next_rand(s));
    float tint = next_rand(s);
    float spill = next_rand(s) * 0.05;
    float tv_r = next_rand(s);
    float blind_r = next_rand(s);
    uint blind_row = min(uint(next_rand(s) * float(GLASS_PX)), GLASS_PX - 1);
    float office_r = next_rand(s);
    float half_r = next_rand(s);
    uint half_k = min(uint(next_rand(s) * 9.0), 8u);
    float neon_r = next_rand(s);

    if (t.stair > 0u && window.x % t.stair == t.stair_off) lit = true;
    bool neon = t.neon > 0u && window.y < 3u && neon_r < 0.8;
    if (neon) lit = true;

    float level = lit ? bright : spill;
    float3 base = lamp_colour(t.lamp) * lerp(0.9, 1.0, tint);
    if (lit && tv_r < 0.08) base = float3(0.5, 0.66, 1.0);
    if (lit && office_r < 0.02) { base = float3(1.0, 1.0, 1.0); level = 1.0; }
    if (neon) { base = neon_colour(t.neon); level = lerp(0.8, 1.0, bright); }

    // Half lit: a diagonal split of the glass; the shadow side stays at spill level.
    bool half_split = lit && !neon && half_r < 0.1;
    float pixel_level = (half_split && x + y > int(half_k)) ? spill : level;

    float gain = neon ? 1.0 : t.gain;
    float fade = lerp(1.0, 0.6, float(y) / float(GLASS_PX - 1));
    float floor_b = 1.0;
    if (t.layout == LAYOUT_CURTAIN) {
        uint fs = pcg(window.y ^ t.salt);
        floor_b = lerp(0.45, 1.0, float(fs) * INV_U32);
    }
    bool wide = t.shape == 0 || t.shape == 1 || t.shape == 4 || t.shape == 6;
    float blinds = (t.layout == LAYOUT_GRID && t.curtain == 1 && lit && blind_r < 0.5 && y == int(blind_row)) ? 0.2 : 1.0;
    float mullion = (t.layout == LAYOUT_GRID && t.curtain == 2 && wide && x == 2) ? 0.35 : 1.0;
    float cross_bar = (t.layout == LAYOUT_GRID && t.curtain == 3 && (x == 2 || y == 2)) ? 0.35 : 1.0;

    float3 color = base * pixel_level * gain * fade * floor_b
        * furniture_factor(h ^ 0xA5A5A5A5u, x, y) * blinds * mullion * cross_bar;

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
