// Cars: each car is two lamp quads at its start pose. The vertex shader slides them along their lane from the time
// uniform, so the CPU does no per-frame work and a car leaving one end of the map reappears at the other.
// Lamps are HDR and unlit: red when the car drives away from the eye, warm white when it comes toward it.

struct Uniforms {
    float4x4 mvp;
    float4 camera_position;
    float4 time; // x = seconds
};

[[vk::binding(0, 0)]]
cbuffer UniformBlock {
    Uniforms data;
}

struct VertexInput {
    [[vk::location(0)]] float3 position : POSITION; // lamp corner at the car's start pose
    [[vk::location(1)]] float4 color : COLOR; // unused
    [[vk::location(2)]] float2 uv : UV; // x = speed (units/s), y = start offset along the lane (units)
    [[vk::location(3)]] float3 normal : NORMAL; // xz = unit direction of travel
};

struct VertexOutput {
    float4 position : SV_POSITION;
    float3 dir : DIR;
    float3 to_camera : TO_CAMERA; // world space
};

static const float LANE_LENGTH = 1024.0;

[shader("vertex")]
VertexOutput vertexMain(VertexInput input) {
    float3 dir = float3(input.normal.x, 0.0, input.normal.z);
    float s0 = input.uv.y;
    float t = s0 + input.uv.x * data.time.x;
    float s = t - LANE_LENGTH * floor(t / LANE_LENGTH); // wraps at the map edge
    float3 world = input.position + dir * (s - s0);

    VertexOutput output;
    output.position = mul(data.mvp, float4(world, 1.0));
    output.dir = dir;
    output.to_camera = data.camera_position.xyz - world;
    return output;
}

[shader("fragment")]
float4 pixelMain(VertexOutput input) : SV_Target0 {
    // dot(dir, world - eye) > 0: the car is moving away, so we see its tail lamps.
    bool away = dot(input.dir, -input.to_camera) > 0.0;
    float3 lamp = away ? float3(1.0, 0.08, 0.04) * 2.0 : float3(1.0, 0.92, 0.75) * 2.5;
    return float4(lamp, 1.0);
}
