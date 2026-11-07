// Bloom composite: additive blend of the blurred half-resolution bright pass
// over the full-resolution scene.
//
// SDL_GPU binding order for compute: uniforms -> sampled textures ->
// samplers -> read-write storage textures. Each sampled texture takes its own
// sampler; gfx_compute_dispatch binds the same sampler for both.

struct CompositeParams {
    float intensity;
    float pad0, pad1, pad2; // float3 pads differently in MSL (32 bytes) vs HLSL (16)
};

[[vk::binding(0, 0)]]
cbuffer UniformBlock {
    CompositeParams params;
}

[[vk::binding(1, 0)]]
Texture2D scene_image;
[[vk::binding(2, 0)]]
Texture2D bloom_image;
[[vk::binding(3, 0)]]
SamplerState scene_sampler;
[[vk::binding(4, 0)]]
SamplerState bloom_sampler;
[[vk::binding(5, 0)]]
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
    float3 bloom = bloom_image.SampleLevel(bloom_sampler, uv, 0).rgb;
    output_image[tid] = float4(scene + bloom * params.intensity, 1.0);
}
