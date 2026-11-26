// Streetlights: one camera-facing soft glow per lamp (src/engine/gfx/shaders/light_sprite.slang). HDR, additive, so
// overlapping glows add up.

import "../src/engine/gfx/shaders/light_sprite";

struct Uniforms {
    float4x4 mvp;
    float4 camera_position;
};

[[vk::binding(0, 0)]]
cbuffer UniformBlock {
    Uniforms data;
}

struct VertexInput {
    [[vk::location(0)]] float3 position : POSITION; // lamp centre
    [[vk::location(1)]] float4 color : COLOR; // rg = corner in [-1,1]^2
    [[vk::location(2)]] float2 uv : UV; // unused
    [[vk::location(3)]] float3 normal : NORMAL; // unused
};

struct VertexOutput {
    float4 position : SV_POSITION;
    float2 corner : CORNER;
};

static const float LAMP_WORLD_SIZE = 3.0; // full width in units
static const float LAMP_MIN_ANGULAR = 0.004; // full width grows with distance so distant lamps stay visible

[shader("vertex")]
VertexOutput vertexMain(VertexInput input) {
    float3 world = sprite_corner_world(input.position, input.color.rg, LAMP_WORLD_SIZE, LAMP_MIN_ANGULAR, data.camera_position.xyz);

    VertexOutput output;
    output.position = mul(data.mvp, float4(world, 1.0));
    output.corner = input.color.rg;
    return output;
}

[shader("fragment")]
float4 pixelMain(VertexOutput input) : SV_Target0 {
    return sprite_shade(input.corner, float3(1.0, 0.5, 0.15), 1.6, 1.0); // sodium
}
