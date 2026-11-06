// Skybox from an equirectangular (2:1) panorama, drawn as one fullscreen
// triangle at the far plane. No cubemap needed.
//
// Depth is reverse-Z with an infinite far plane (see camera_perspective):
// clip z = 0 is the far plane, and the inverse view-projection of an NDC point
// at z = 0 has w = 0, i.e. it is a pure world-space view direction that
// ignores camera translation. The pipeline must use GREATER_OR_EQUAL so z = 0
// passes against the cleared depth.

struct Uniforms {
    float4x4 inverse_view_projection;
};

[[vk::binding(0, 0)]]
cbuffer UniformBlock {
    Uniforms data;
}

[[vk::binding(1, 0)]] Texture2D tex;
[[vk::binding(2, 0)]] SamplerState tex_sampler;

struct VertexInput {
    [[vk::location(0)]] float3 position : POSITION;
};

struct VertexOutput {
    float4 position : SV_POSITION;
    float3 direction : DIRECTION;
};

[shader("vertex")]
VertexOutput vertexMain(VertexInput input) {
    VertexOutput output;
    output.position = float4(input.position.xy, 0.0, 1.0);
    output.direction = mul(data.inverse_view_projection, float4(input.position.xy, 0.0, 1.0)).xyz;
    return output;
}

static const float PI = 3.14159265358979;

[shader("fragment")]
float4 pixelMain(VertexOutput input) : SV_Target0 {
    float3 d = normalize(input.direction);
    float u = atan2(d.z, d.x) / (2.0 * PI) + 0.5;
    float v = acos(clamp(d.y, -1.0, 1.0)) / PI;
    // Explicit LOD: atan2's wrap at the seam would otherwise give the
    // hardware a huge UV derivative and a one-pixel-wide line.
    return tex.SampleLevel(tex_sampler, float2(u, v), 0);
}
