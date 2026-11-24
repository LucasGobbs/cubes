// Night sky on the lampshade cylinder: samples the sky texture (city_sky_gen). Repeats in u, clamps in v.

struct Uniforms {
    float4x4 mvp;
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
};

[shader("vertex")]
VertexOutput vertexMain(VertexInput input) {
    VertexOutput output;
    output.position = mul(data.mvp, float4(input.position, 1.0));
    output.color = input.color;
    output.uv = input.uv;
    return output;
}

[[vk::binding(1, 0)]]
Texture2D sky_texture;
[[vk::binding(2, 0)]]
SamplerState sky_sampler;

[shader("fragment")]
float4 pixelMain(VertexOutput input) : SV_Target0 {
    // The compute shader writes display-referred values into a UNORM texture; linearize for the sRGB swapchain.
    float4 texel = sky_texture.Sample(sky_sampler, input.uv);
    // Vertex colour fades the part below the horizon to black (ground haze).
    return float4(pow(texel.rgb, 2.2) * input.color.rgb, 1.0);
}
