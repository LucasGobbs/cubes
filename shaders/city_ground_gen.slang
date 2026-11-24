// Ground texture: one texel per unit of the city grid (1 texel = 1 unit = 1 lane). Reads the road plan as packed bits
// (bit i of word i / 32 = cell i, row-major by z) and paints streets as warm asphalt under sodium lamps; everything
// else is near-black blue. Output is display-referred: the ground fragment shader linearizes it.
//
// SDL_GPU compute binding order: read-only storage buffers -> read-write storage textures.

static const uint CITY_SIZE = 2048; // = CITY_SIZE in plan.odin: keep equal
static const float PI = 3.14159265;
static const float LAMP_SPACING = 8.0; // units between lamps along each kerb
static const float INV_U32 = 1.0 / 4294967296.0;

[[vk::binding(0, 0)]]
StructuredBuffer<uint> road_bits;

[[vk::binding(1, 0)]]
RWTexture2D<float4> output_image;

uint pcg(uint v) {
    uint state = v * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

// Off-city cells count as not road.
bool is_road(int2 p) {
    if (p.x < 0 || p.y < 0 || p.x >= int(CITY_SIZE) || p.y >= int(CITY_SIZE)) return false;
    uint i = uint(p.y) * CITY_SIZE + uint(p.x);
    return ((road_bits[i >> 5] >> (i & 31u)) & 1u) != 0u;
}

// Road cell with a non-road 4-neighbour: the kerb line.
bool is_kerb(int2 p) {
    return is_road(p) && (!is_road(p + int2(-1, 0)) || !is_road(p + int2(1, 0)) || !is_road(p + int2(0, -1)) || !is_road(p + int2(0, 1)));
}

// Lamp pool along one axis: 1 under a lamp, 0.55 halfway between two.
float lamp_pool(float along) {
    return 0.55 + 0.45 * pow(abs(cos(PI * along / LAMP_SPACING)), 3.0);
}

[shader("compute")]
[numthreads(8, 8, 1)]
void computeMain(uint2 tid : SV_DispatchThreadID)
{
    int2 p = int2(tid);
    if (!is_road(p)) {
        output_image[tid] = float4(0.01, 0.01, 0.015, 1.0);
        return;
    }

    // Lamps line the kerbs: a street running along z is lit by its position along z, and vice versa.
    // Intersections (kerbs on both axes) take the brighter of the two pools.
    bool x_kerb = !is_road(p + int2(-1, 0)) || !is_road(p + int2(1, 0));
    bool z_kerb = !is_road(p + int2(0, -1)) || !is_road(p + int2(0, 1));
    float pool_x = lamp_pool(float(p.x) + 0.5);
    float pool_z = lamp_pool(float(p.y) + 0.5);
    float pool = (x_kerb && !z_kerb) ? pool_z : (z_kerb && !x_kerb) ? pool_x : max(pool_x, pool_z);

    // Lamp reach: the lane one in from the kerb is brighter; the kerb line itself is slightly darker.
    bool edge = is_kerb(p);
    bool inner = !edge && (is_kerb(p + int2(-1, 0)) || is_kerb(p + int2(1, 0)) || is_kerb(p + int2(0, -1)) || is_kerb(p + int2(0, 1)));
    float reach = edge ? 0.8 : (inner ? 1.35 : 1.0);

    uint h = pcg(tid.x ^ (tid.y << 16));
    float grain = 0.8 + 0.2 * float(h) * INV_U32;

    float3 asphalt = float3(0.22, 0.17, 0.12);
    output_image[tid] = float4(saturate(asphalt * grain * pool * reach), 1.0);
}
