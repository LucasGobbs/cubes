// Bloom prefilter: soft-knee threshold on max(r, g, b). Reads the full
// resolution scene, writes a half resolution image of the bright parts.
//
// SDL_GPU binding order for compute: uniforms -> sampled textures ->
// samplers -> read-write storage textures.

struct PrefilterParams {
    float threshold;
    float knee;
    float2 pad;
};

[[vk::binding(0, 0)]]
cbuffer UniformBlock {
    PrefilterParams params;
}

[[vk::binding(1, 0)]]
Texture2D input_image;
[[vk::binding(2, 0)]]
SamplerState input_sampler;
[[vk::binding(3, 0)]]
RWTexture2D<float4> output_image;

[shader("compute")]
[numthreads(8, 8, 1)]
void computeMain(uint2 tid : SV_DispatchThreadID)
{
    uint width, height;
    output_image.GetDimensions(width, height);
    if (tid.x >= width || tid.y >= height) { return; }

    float2 uv = (float2(tid) + 0.5) / float2(width, height);
    float3 c = input_image.SampleLevel(input_sampler, uv, 0).rgb;

    float b = max(c.r, max(c.g, c.b));
    float soft = clamp(b - params.threshold + params.knee, 0.0, 2.0 * params.knee);
    soft = soft * soft / (4.0 * params.knee + 1e-4);
    float contrib = max(soft, b - params.threshold) / max(b, 1e-4);
    output_image[tid] = float4(c * contrib, 1.0);
}
