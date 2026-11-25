// Exposure, ACES filmic tonemap (Narkowicz fit), contrast and saturation: HDR linear in, display-referred linear out.
// The swapchain is *_SRGB, so the hardware encodes on write.
//
// SDL_GPU binding order for compute: uniforms -> sampled textures -> samplers -> read-write storage textures.

struct TonemapParams {
    float exposure_scale; // 2^EV
    float contrast;       // 1 = unchanged, pivot at mid grey
    float saturation;     // 1 = unchanged, 0 = grey
    float pad;
};

[[vk::binding(0, 0)]]
cbuffer UniformBlock {
    TonemapParams params;
}

[[vk::binding(1, 0)]]
Texture2D input_image;
[[vk::binding(2, 0)]]
SamplerState input_sampler;
[[vk::binding(3, 0)]]
RWTexture2D<float4> output_image;

float3 aces(float3 x) {
    return saturate((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14));
}

[shader("compute")]
[numthreads(8, 8, 1)]
void computeMain(uint2 tid : SV_DispatchThreadID)
{
    uint width, height;
    output_image.GetDimensions(width, height);
    if (tid.x >= width || tid.y >= height) { return; }

    float2 uv = (float2(tid) + 0.5) / float2(width, height);
    float3 color = input_image.SampleLevel(input_sampler, uv, 0).rgb * params.exposure_scale;
    color = aces(color);
    // Contrast around mid grey in display space, then saturation around luma.
    color = saturate((color - 0.18) * params.contrast + 0.18);
    float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
    color = saturate(lerp(float3(luma, luma, luma), color, params.saturation));
    output_image[tid] = float4(color, 1.0);
}
