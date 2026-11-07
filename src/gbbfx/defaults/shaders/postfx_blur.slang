// Separable gaussian blur: one 1-D pass per dispatch. `direction` picks the
// axis ({1,0} horizontal, {0,1} vertical); sigma = radius / 2.
//
// SDL_GPU binding order for compute: uniforms -> sampled textures ->
// samplers -> read-write storage textures. Read with SampleLevel: compute
// shaders have no derivatives.

struct BlurParams {
    float2 direction;
    int radius;
    float pad;
};

[[vk::binding(0, 0)]]
cbuffer UniformBlock {
    BlurParams params;
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

    float2 size = float2(width, height);
    float2 uv = (float2(tid) + 0.5) / size;
    float2 texel = 1.0 / size;

    float sigma = max(params.radius, 1) / 2.0;
    float4 sum = 0;
    float weight_sum = 0;
    for (int i = -params.radius; i <= params.radius; i++) {
        float weight = exp(-float(i * i) / (2.0 * sigma * sigma));
        sum += input_image.SampleLevel(input_sampler, uv + params.direction * float(i) * texel, 0) * weight;
        weight_sum += weight;
    }
    output_image[tid] = sum / weight_sum;
}
