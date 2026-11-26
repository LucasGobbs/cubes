// Bloom composite: sums the blurred levels (half, quarter, eighth; bilinear), subtracts a black floor, adds over the scene.
// One-level bloom passes zero weights for the unused levels.
//
// SDL_GPU binding order for compute: uniforms -> sampled textures ->
// samplers -> read-write storage textures.

struct CompositeParams {
    float4 weights;     // xyz: level weights, w: intensity
    float4 black_floor; // x: floor subtracted from the summed glow
};

[[vk::binding(0, 0)]]
cbuffer UniformBlock {
    CompositeParams params;
}

[[vk::binding(1, 0)]]
Texture2D scene_image;
[[vk::binding(2, 0)]]
Texture2D level_half_image;
[[vk::binding(3, 0)]]
Texture2D level_quarter_image;
[[vk::binding(4, 0)]]
Texture2D level_eighth_image;

[[vk::binding(5, 0)]]
SamplerState scene_sampler;
[[vk::binding(6, 0)]]
SamplerState level_half_sampler;
[[vk::binding(7, 0)]]
SamplerState level_quarter_sampler;
[[vk::binding(8, 0)]]
SamplerState level_eighth_sampler;

[[vk::binding(9, 0)]]
RWTexture2D<float4> output_image;

[shader("compute")]
[numthreads(8, 8, 1)]
void computeMain(uint3 id : SV_DispatchThreadID)
{
    uint w, h;
    output_image.GetDimensions(w, h);
    if (id.x >= w || id.y >= h) return;

    float2 uv = (float2(id.xy) + 0.5) / float2(w, h);
    float3 scene = scene_image.SampleLevel(scene_sampler, uv, 0).rgb;
    float3 glow = level_half_image.SampleLevel(level_half_sampler, uv, 0).rgb * params.weights.x
                + level_quarter_image.SampleLevel(level_quarter_sampler, uv, 0).rgb * params.weights.y
                + level_eighth_image.SampleLevel(level_eighth_sampler, uv, 0).rgb * params.weights.z;
    glow = max(glow - params.black_floor.x, 0.0);
    output_image[id.xy] = float4(scene + glow * params.weights.w, 1.0);
}
