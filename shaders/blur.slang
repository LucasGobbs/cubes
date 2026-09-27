// Post-processing blur: 5x5 box filter over the rendered scene.
//
// SDL_GPU MSL binding order for compute: sampled textures -> samplers ->
// read-write storage textures (uniform buffers would come before all of
// these). Read with SampleLevel: compute shaders have no derivatives.

[[vk::binding(0, 0)]]
Texture2D input_image;
[[vk::binding(1, 0)]]
SamplerState input_sampler;
[[vk::binding(2, 0)]]
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

    float4 sum = 0;
    for (int y = -2; y <= 2; y++) {
        for (int x = -2; x <= 2; x++) {
            sum += input_image.SampleLevel(input_sampler, uv + float2(x, y) * texel, 0);
        }
    }
    output_image[tid] = sum / 25.0;
}
