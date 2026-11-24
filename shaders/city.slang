// Unlit textured geometry for the city: the window atlas times vertex colour. Vertex alpha carries the atlas tile.
// Distance fog is per pixel: the walls are long quads, so per-vertex fog would smear across them.

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
    float4 color : COLOR;
    float2 uv : UV;
    float3 to_camera : TO_CAMERA; // world space: the mesh is already in world space
    float4 fog : FOG;
};

[shader("vertex")]
VertexOutput vertexMain(VertexInput input) {
    VertexOutput output;
    output.position = mul(data.mvp, float4(input.position, 1.0));
    output.color = input.color;
    output.uv = input.uv;
    output.to_camera = data.camera_position.xyz - input.position;
    output.fog = data.fog;
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
    // Alpha is (tile + 0.5) / 36 (see building_wall): uv wraps inside its tile, so the atlas tile is picked here.
    // 36 = TILE_COUNT and 6 = TILE_COUNT_SIDE in window_texture.odin.
    uint tile = min(uint(input.color.a * 36.0), 35u);
    // Mip from the unwrapped uv: frac() jumps at every window row, which would pick the coarsest mip on those lines.
    float2 grad_x = ddx(input.uv) / 6.0;
    float2 grad_y = ddy(input.uv) / 6.0;
    float2 uv = (float2(tile % 6, tile / 6) + frac(input.uv)) / 6.0;
    float4 texel = window_texture.SampleGrad(window_sampler, uv, grad_x, grad_y);
    float3 lit = pow(texel.rgb, 2.2) * input.color.rgb;
    // Night grade: half-strength S-curve in linear light. Dim surfaces sink toward black; lit windows keep their level.
    lit = lerp(lit, lit * lit * (3.0 - 2.0 * lit), 0.5);

    // Same ramp as sea.slang: clear at 60% of the view distance, fully fogged at 100%.
    float dist = length(input.to_camera);
    float t = input.fog.a > 0.0 ? saturate((dist - 0.6 * input.fog.a) / (0.4 * input.fog.a)) : 0.0;
    return float4(lerp(lit, input.fog.rgb, t), 1.0);
}
