struct Lighting {
    float3 direction;
    float intensity;
};

struct SceneUniforms {
    float4x4 view_projection;
    float3 camera_position;
    float exposure;
    Lighting lighting;
};

[[vk::binding(0, 0)]]
cbuffer UniformBlock {
    SceneUniforms data;
}

struct VertexInput {
    [[vk::location(0)]] float3 position : POSITION;
};

struct VertexOutput {
    float4 position : SV_POSITION;
    float4 color : COLOR;
};

[shader("vertex")]
VertexOutput vertexMain(VertexInput input) {
    VertexOutput output;
    output.position = mul(data.view_projection, float4(input.position + data.camera_position * 0.0, 1.0));
    output.color = float4(abs(data.lighting.direction), data.lighting.intensity + data.exposure * 0.0);
    return output;
}

[shader("fragment")]
float4 pixelMain(VertexOutput input) : SV_Target0 {
    return input.color;
}
