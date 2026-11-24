// Unlit textured geometry for the city: the window atlas times vertex color.

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
Texture2D window_texture;
[[vk::binding(2, 0)]]
SamplerState window_sampler;

[shader("fragment")]
float4 pixelMain(VertexOutput input) : SV_Target0 {
    // The compute shader writes display-referred values into a UNORM texture (storage textures cannot be sRGB);
    // the swapchain is sRGB, so linearize here or dark windows come out washed grey.
    float4 texel = window_texture.Sample(window_sampler, input.uv);
    return float4(pow(texel.rgb, 2.2), texel.a) * input.color;
}
