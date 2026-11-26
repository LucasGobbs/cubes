// Aviation beacons and roof lights: one camera-facing billboard per light, as city_lights.slang (light_sprite.slang).
// Per-light data: color.rg = corner in [-1,1]^2, color.b = blink phase in [0,1), color.a = blink period in seconds,
// uv.x = 1 to blink (0 steady), uv.y = full width in units, normal = HDR tint. The blink runs on the GPU from time, so
// the CPU never rewrites the mesh.

import "../src/engine/gfx/shaders/light_sprite";

struct Uniforms {
    float4x4 mvp;
    float4 camera_position;
    float4 fog; // rgb = linear fog colour, a = view distance (<= 0 = off)
    float4 time; // x = seconds
    float4 gain; // x = brightness multiplier: 1 at night, 0 by day
};

[[vk::binding(0, 0)]]
cbuffer UniformBlock {
    Uniforms data;
}

struct VertexInput {
    [[vk::location(0)]] float3 position : POSITION; // light centre
    [[vk::location(1)]] float4 color : COLOR; // rg = corner, b = phase, a = period
    [[vk::location(2)]] float2 uv : UV; // x = blink flag, y = width
    [[vk::location(3)]] float3 normal : NORMAL; // HDR tint
};

struct VertexOutput {
    float4 position : SV_POSITION;
    float2 corner : CORNER;
    float3 glow : GLOW; // tint times brightness, constant over the quad
};

static const float BEACON_MIN_ANGULAR = 0.003; // full width grows with distance so distant lights stay visible

[shader("vertex")]
VertexOutput vertexMain(VertexInput input) {
    float3 world = sprite_corner_world(input.position, input.color.rg, input.uv.y, BEACON_MIN_ANGULAR, data.camera_position.xyz);
    float brightness = input.uv.x > 0.5 ? blink(data.time.x, input.color.b, input.color.a) : 1.0;

    VertexOutput output;
    output.position = mul(data.mvp, float4(world, 1.0));
    output.corner = input.color.rg;
    output.glow = input.normal * brightness * data.gain.x * sprite_fog_fade(length(input.position - data.camera_position.xyz), data.fog);
    return output;
}

[shader("fragment")]
float4 pixelMain(VertexOutput input) : SV_Target0 {
    return sprite_shade(input.corner, input.glow, 1.6, 1.0);
}
