// Instanced textured pipeline: same shading as textured.slang, but the
// per-instance model matrix comes from a storage buffer indexed by
// SV_InstanceID instead of a per-draw MVP uniform. One draw per
// (mesh, material) run instead of one draw per entity.
//
// SDL_GPU MSL binding order for vertex stage: uniform buffers first, then
// read-only storage buffers.

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

[[vk::binding(2, 0)]] Texture2D tex;
[[vk::binding(3, 0)]] SamplerState tex_sampler;

struct VertexInput {
    [[vk::location(0)]] float3 position : POSITION;
    [[vk::location(1)]] float4 color : COLOR;
    [[vk::location(2)]] float2 uv : UV;
};

struct VertexOutput {
    float4 position : SV_POSITION;
    float4 color : COLOR;
    float2 uv : UV;
};

[shader("vertex")]
VertexOutput vertexMain(VertexInput input, uint instance_id : SV_InstanceID) {
    float4x4 model = instance_transforms[instance_id + data.first_instance];
    VertexOutput output;
    output.position = mul(data.view_projection, mul(model, float4(input.position, 1.0)));
    output.color = input.color;
    output.uv = input.uv;
    return output;
}

[shader("fragment")]
float4 pixelMain(VertexOutput input) : SV_Target0 {
    return tex.Sample(tex_sampler, input.uv) * input.color;
}
