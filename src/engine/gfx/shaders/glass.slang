struct Uniforms {
    float4x4 mvp;
    float4x4 model;
    float4x4 normal_matrix;
    float4 camera_pos;
    float4 tint;
};

[[vk::binding(0, 0)]]
cbuffer UniformBlock {
    Uniforms data;
}

struct VertexInput {
    [[vk::location(0)]] float3 position : POSITION;
    [[vk::location(3)]] float3 normal : NORMAL;
};

struct VertexOutput {
    float4 position : SV_POSITION;
    float3 world_pos : TEXCOORD0;
    float3 world_normal : TEXCOORD1;
};

[shader("vertex")]
VertexOutput vertexMain(VertexInput input) {
    VertexOutput output;
    float4 world = mul(data.model, float4(input.position, 1.0));
    output.position = mul(data.mvp, float4(input.position, 1.0));
    output.world_pos = world.xyz;
    output.world_normal = mul(data.normal_matrix, float4(input.normal, 0.0)).xyz;
    return output;
}

[shader("fragment")]
float4 pixelMain(VertexOutput input) : SV_Target0 {
    float3 N = normalize(input.world_normal);
    float3 V = normalize(data.camera_pos.xyz - input.world_pos);
    if (dot(N, V) < 0.0) N = -N;

    float fresnel = pow(1.0 - saturate(dot(N, V)), 3.0);

    float3 light_dir = normalize(float3(0.4, 1.0, 0.6));
    float3 H = normalize(light_dir + V);
    float spec = pow(saturate(dot(N, H)), 128.0);

    float3 color = data.tint.rgb * 0.15 + fresnel * float3(0.9, 0.95, 1.0) + spec;
    float alpha = saturate(data.tint.a * 0.35 + fresnel * 0.65 + spec);
    return float4(color, alpha);
}
