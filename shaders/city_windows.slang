// Window atlas: a 512x512 texture of 64x64 windows, 8x8 px each. Each window is
// lit or dark by a PCG hash of (window x, window y, seed). A 1 px black border
// surrounds every window, so the lit area is 6x6.
//
// SDL_GPU binding order for compute: uniforms -> read-write storage textures.

static const uint WINDOWS_PER_SIDE = 64;
static const uint WINDOW_PX = 8;
static const uint BORDER_PX = 1;

// Padded to 16 bytes: push uniform data is read as one vec4.
struct WindowParams {
    uint seed;
    uint pad0;
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

[shader("compute")]
[numthreads(8, 8, 1)]
void computeMain(uint2 tid : SV_DispatchThreadID)
{
    uint2 window = tid / WINDOW_PX;
    uint2 local = tid % WINDOW_PX;

    uint h = pcg(pcg(window.x ^ (window.y << 16)) + params.seed);
    bool lit = h < 0x80000000u;
    bool border = min(local.x, local.y) < BORDER_PX || max(local.x, local.y) >= WINDOW_PX - BORDER_PX;

    float4 color = float4(0.0, 0.0, 0.0, 1.0);
    if (lit && !border) color = float4(1.0, 0.95, 0.8, 1.0);
    output_image[tid] = color;
}
