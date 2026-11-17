struct Uniforms {
    float4x4 mvp;
    float4x4 normal_matrix;
};

[[vk::binding(0, 0)]]
cbuffer UniformBlock {
    Uniforms data;
}

[[vk::binding(1, 0)]] Texture2D tex;
[[vk::binding(2, 0)]] SamplerState tex_sampler;

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
    float3 normal : NORMAL;
};

[shader("vertex")]
VertexOutput vertexMain(VertexInput input) {
    VertexOutput output;
    output.position = mul(data.mvp, float4(input.position, 1.0));
    output.color = input.color;
    output.uv = input.uv;
    output.normal = mul(data.normal_matrix, float4(input.normal, 0.0)).xyz;
    return output;
}

[shader("fragment")]
float4 pixelMain(VertexOutput input) : SV_Target0 {
    float4 albedo = tex.Sample(tex_sampler, input.uv) * input.color;
    float3 n = input.normal;
    // zero normal = unlit (overlays, text, editor UI)
    if (dot(n, n) < 1e-8) return albedo;
    n = normalize(n);
    float3 light_dir = normalize(float3(0.4, 1.0, 0.6));
    float3 ambient = float3(0.12, 0.12, 0.12);
    float n_dot_l = max(dot(n, light_dir), 0.0);
    // three hard bands (0.35 / 0.7 / 1.0); smoothstep width = AA edge
    const float w = 0.01;
    float s1 = smoothstep(0.30 - w, 0.30 + w, n_dot_l);
    float s2 = smoothstep(0.65 - w, 0.65 + w, n_dot_l);
    float band = 0.35 + 0.35 * s1 + 0.30 * s2;
    return float4(albedo.rgb * (ambient + band), albedo.a);
}
