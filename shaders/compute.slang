// Compute shader example: element-wise transform out[i] = in[i] * 2 + 1.
//
// Buffer ordering must follow SDL_GPU's MSL convention:
// uniforms -> read-only storage buffers -> read-write storage buffers,
// so input lands on [[buffer(0)]] and output on [[buffer(1)]].

[[vk::binding(0, 0)]]
StructuredBuffer<float> inputData;

[[vk::binding(1, 0)]]
RWStructuredBuffer<float> outputData;

[shader("compute")]
[numthreads(64, 1, 1)]
void computeMain(uint index : SV_DispatchThreadID)
{
    outputData[index] = inputData[index] * 2.0 + 1.0;
}
