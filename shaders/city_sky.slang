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
    // Vertex colour (1 at the horizon, 0 at the bottom ring) fades the part below the horizon to a dark blue-grey, not
    // to the red horizon glow.
    static const float3 BELOW = float3(0.004, 0.005, 0.008); // = CITY_FOG rgb in scene.odin: keep equal, so the ground fogs into the sky
    float3 glow = pow(texel.rgb, 2.2);
    return float4(lerp(BELOW, glow, pow(input.color.r, 4.0)), 1.0);
}
