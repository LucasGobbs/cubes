// Ground quad under the city: samples the ground texture (city_ground_gen) and fogs per pixel like the buildings.

struct Uniforms {
    float4x4 mvp;
    float4 camera_position;
    float4 fog; // rgb = linear fog color, a = view distance (<= 0 = off)
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
    float2 uv : UV;
    float3 to_camera : TO_CAMERA; // world space: the quad is already in world space
    float4 fog : FOG;
};

[shader("vertex")]
VertexOutput vertexMain(VertexInput input) {
    VertexOutput output;
    output.position = mul(data.mvp, float4(input.position, 1.0));
    output.uv = input.uv;
    output.to_camera = data.camera_position.xyz - input.position;
    output.fog = data.fog;
    return output;
}

[[vk::binding(1, 0)]]
Texture2D ground_texture;
[[vk::binding(2, 0)]]
SamplerState ground_sampler;

[shader("fragment")]
float4 pixelMain(VertexOutput input) : SV_Target0 {
    // The compute shader writes display-referred values into a UNORM texture; linearize for the sRGB swapchain.
    float3 lit = pow(ground_texture.Sample(ground_sampler, input.uv).rgb, 2.2);

    // Same ramp as city.slang: clear at 60% of the view distance, fully fogged at 100%.
    float dist = length(input.to_camera);
    float t = input.fog.a > 0.0 ? saturate((dist - 0.6 * input.fog.a) / (0.4 * input.fog.a)) : 0.0;
    return float4(lerp(lit, input.fog.rgb, t), 1.0);
}
