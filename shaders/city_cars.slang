// Cars: each lamp is a camera-facing billboard (src/engine/gfx/shaders/light_sprite.slang). The vertex shader slides
// its centre along the lane from the time uniform, so the CPU does no per-frame work and a car leaving one end of the
// map reappears at the other. The vertex colour.rg carries the corner in [-1,1]^2 and colour.b the lane length. Lamps
// are HDR, round soft glows: red when the car drives away from the eye, warm white when it comes toward it.

import "../src/engine/gfx/shaders/light_sprite";

struct Uniforms {
    float4x4 mvp;
    float4 camera_position;
    float4 fog; // rgb = linear fog colour, a = view distance (<= 0 = off)
    float4 time; // x = seconds
    float4 gain; // x = brightness multiplier (the car lamps stay faintly on by day)
};

[[vk::binding(0, 0)]]
cbuffer UniformBlock {
    Uniforms data;
}

struct VertexInput {
    [[vk::location(0)]] float3 position : POSITION; // lamp centre at the car's start pose
    [[vk::location(1)]] float4 color : COLOR; // rg = corner in [-1,1]^2, b = lane length (units)
    [[vk::location(2)]] float2 uv : UV; // x = speed (units/s), y = start offset along the lane (units)
    [[vk::location(3)]] float3 normal : NORMAL; // xz = unit direction of travel
};

struct VertexOutput {
    float4 position : SV_POSITION;
    float2 corner : CORNER;
    float3 dir : DIR;
    float3 to_camera : TO_CAMERA; // world space
    float gain : GAIN;
};

static const float LAMP_WORLD_SIZE = 1.4; // full width in units
static const float LAMP_MIN_ANGULAR = 0.004; // full width grows with distance so distant lamps stay visible

[shader("vertex")]
VertexOutput vertexMain(VertexInput input) {
    float3 dir = float3(input.normal.x, 0.0, input.normal.z);
    float s0 = input.uv.y;
    float t = s0 + input.uv.x * data.time.x;
    float L = input.color.b;
    float s = t - L * floor(t / L); // wraps at the map edge
    float3 centre = input.position + dir * (s - s0);

    float3 eye = data.camera_position.xyz;
    float3 world = sprite_corner_world(centre, input.color.rg, LAMP_WORLD_SIZE, LAMP_MIN_ANGULAR, eye);

    VertexOutput output;
    output.position = mul(data.mvp, float4(world, 1.0));
    output.corner = input.color.rg;
    output.dir = dir;
    output.to_camera = eye - centre;
    output.gain = data.gain.x * sprite_fog_fade(length(output.to_camera), data.fog);
    return output;
}

[shader("fragment")]
float4 pixelMain(VertexOutput input) : SV_Target0 {
    // dot(dir, centre - eye) > 0: the car is moving away, so we see its tail lamps.
    bool away = dot(input.dir, -input.to_camera) > 0.0;
    float3 tint = away ? float3(1.0, 0.08, 0.04) : float3(1.0, 0.92, 0.75);
    return sprite_shade(input.corner, tint, 1.6, 1.0) * input.gain;
}
