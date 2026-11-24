// Unlit textured geometry for the city: the window atlas times vertex colour. Vertex alpha carries the atlas tile.

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
    // Alpha is (tile + 0.5) / 16 (see building_wall): uv wraps inside its tile, so the atlas tile is picked here.
    uint tile = min(uint(input.color.a * 16.0), 15u);
    float2 uv = (float2(tile % 4, tile / 4) + frac(input.uv)) / 4.0;
    float4 texel = window_texture.Sample(window_sampler, uv);
    return float4(pow(texel.rgb, 2.2) * input.color.rgb, 1.0);
}
