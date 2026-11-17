// Instanced depth-only pass for the sun shadow map. Per-instance transforms come
// from the renderer's storage buffer by SV_InstanceID, like textured_instanced.slang.
// No color output; the fragment stage exists only because goose requires one.

struct Uniforms {
    float4x4 view_projection;
    uint first_instance;
};

[[vk::binding(0, 0)]]
cbuffer UniformBlock {
    Uniforms data;
}

[[vk::binding(1, 0)]]
StructuredBuffer<float4x4> instance_transforms;

struct VertexInput {
    [[vk::location(0)]] float3 position : POSITION;
    [[vk::location(1)]] float4 color : COLOR;
    [[vk::location(2)]] float2 uv : UV;
    [[vk::location(3)]] float3 normal : NORMAL;
};

struct VertexOutput {
    float4 position : SV_POSITION;
};

[shader("vertex")]
VertexOutput vertexMain(VertexInput input, uint instance_id : SV_InstanceID) {
    float4x4 model = instance_transforms[instance_id + data.first_instance];
    VertexOutput output;
    output.position = mul(data.view_projection, mul(model, float4(input.position, 1.0)));
    return output;
}

[shader("fragment")]
void pixelMain() {}
