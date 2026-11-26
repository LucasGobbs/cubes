// Unlit textured geometry for the city: the window atlas times vertex colour. Vertex alpha carries the atlas tile.
// Distance fog is per pixel: the walls are long quads, so per-vertex fog would smear across them.

import "../src/engine/gfx/shaders/fog";
import constants;

struct Uniforms {
    float4x4 mvp;
    float4 camera_position;
    float4 fog; // rgb = linear fog color, a = view distance (<= 0 = off)
    float4 day; // x = daylight (0 night .. 1 day), y = lightning flash (0..1)
};

[[vk::binding(0, 0)]]
cbuffer UniformBlock {
    Uniforms data;
}

struct VertexInput {
    [[vk::location(0)]] float3 position : POSITION;
    [[vk::location(1)]] float4 color : COLOR;
    [[vk::location(2)]] float2 uv : UV;
    [[vk::location(3)]] float3 normal : NORMAL;
};

struct VertexOutput {
    float4 position : SV_POSITION;
    float4 color : COLOR;
    float2 uv : UV;
    float3 to_camera : TO_CAMERA; // world space: the mesh is already in world space
    float4 fog : FOG;
    float4 day : DAY;
};

[shader("vertex")]
VertexOutput vertexMain(VertexInput input) {
    VertexOutput output;
    output.position = mul(data.mvp, float4(input.position, 1.0));
    output.color = input.color;
    output.uv = input.uv;
    output.to_camera = data.camera_position.xyz - input.position;
    output.fog = data.fog;
    output.day = data.day;
    return output;
}

[[vk::binding(1, 0)]]
Texture2D window_texture;
[[vk::binding(2, 0)]]
SamplerState window_sampler;

[shader("fragment")]
float4 pixelMain(VertexOutput input) : SV_Target0 {
    // The compute shader writes display-referred values into a UNORM texture (storage textures cannot be sRGB);
    // the swapchain is sRGB, so linearize here or dark windows come out washed grey.
    // Alpha is (tile + 0.5) / TILE_COUNT (see building_wall): uv wraps inside its tile, so the atlas tile is picked here.
    // TILE_COUNT and TILE_COUNT_SIDE come from constants.slang (shaders/constants.json).
    uint tile = min(uint(input.color.a * float(TILE_COUNT)), TILE_COUNT - 1u);
    // Mip from the unwrapped uv: frac() jumps at every window row, which would pick the coarsest mip on those lines.
    float2 grad_x = ddx(input.uv) / float(TILE_COUNT_SIDE);
    float2 grad_y = ddy(input.uv) / float(TILE_COUNT_SIDE);
    float2 uv = (float2(tile % TILE_COUNT_SIDE, tile / TILE_COUNT_SIDE) + frac(input.uv)) / float(TILE_COUNT_SIDE);
    float4 texel = window_texture.SampleGrad(window_sampler, uv, grad_x, grad_y);
    float3 lit = pow(texel.rgb, 2.2) * input.color.rgb;
    // Night grade: half-strength S-curve in linear light, only on dark values (luma < ~0.35); it sinks roofs and
    // dim spill toward black. Lit windows (luma above ~0.5) are untouched and then emissive: the boost grows them
    // up to 3.2x so the bloom threshold catches them.
    float luma = dot(lit, float3(0.2126, 0.7152, 0.0722));
    float dark = 1.0 - smoothstep(0.1, 0.35, luma);
    lit = lerp(lit, lit * lit * (3.0 - 2.0 * lit), 0.5 * dark);
    lit *= 1.0 + 2.2 * smoothstep(0.08, 0.45, luma) * (1.0 - input.day.x); // boost is night-only: by day lit windows stay dim
    // Day: windows dim, the wall gets a grey ambient term; mesh roofs and stripes are black (colour 0), so
    // albedo floors at grey. A lightning flash adds a cool fill.
    float3 albedo = max(input.color.rgb, 0.3);
    lit = lit * (1.0 - 0.8 * input.day.x) + input.day.x * float3(0.18, 0.2, 0.24) * albedo;
    lit += input.day.y * 0.25 * float3(0.7, 0.8, 1.0) * albedo;

    // Distance fog: see src/engine/gfx/shaders/fog.slang.
    return float4(apply_fog_soft(lit, length(input.to_camera), input.fog), 1.0);
}
