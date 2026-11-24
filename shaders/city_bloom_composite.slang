// City bloom composite: adds three blurred bloom levels (half, quarter, eighth resolution) over the full-resolution
// scene. Bilinear sampling upsamples each level for free; the wide levels add the soft glow round the whole city.
//
// SDL_GPU binding order for compute: uniforms -> sampled textures -> samplers -> read-write storage textures.
// Each sampled texture takes its own sampler; gfx_compute_dispatch binds the same sampler for all of them.

struct CityBloomParams {
    float4 weights; // xyz: level weights (half, quarter, eighth); w: intensity
};

[[vk::binding(0, 0)]]
cbuffer UniformBlock {
    CityBloomParams params;
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
void computeMain(uint2 tid : SV_DispatchThreadID)
{
    uint width, height;
    output_image.GetDimensions(width, height);
    if (tid.x >= width || tid.y >= height) { return; }

    float2 uv = (float2(tid) + 0.5) / float2(width, height);
    float3 scene = scene_image.SampleLevel(scene_sampler, uv, 0).rgb;
    float3 half_glow = level_half_image.SampleLevel(level_half_sampler, uv, 0).rgb;
    float3 quarter_glow = level_quarter_image.SampleLevel(level_quarter_sampler, uv, 0).rgb;
    float3 eighth_glow = level_eighth_image.SampleLevel(level_eighth_sampler, uv, 0).rgb;
    float3 glow = half_glow * params.weights.x + quarter_glow * params.weights.y + eighth_glow * params.weights.z;
    // Black floor: the haze lifts only what is above it, so dark streets and roofs stay near black.
    static const float3 BLOOM_FLOOR = float3(0.012, 0.012, 0.016);
    glow = max(glow - BLOOM_FLOOR, 0.0);
    output_image[tid] = float4(scene + glow * params.weights.w, 1.0);
}
