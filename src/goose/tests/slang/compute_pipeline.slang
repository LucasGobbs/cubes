struct ComputeUniforms {
    float scale;
    float bias;
    uint count;
};

[[vk::binding(0, 0)]]
cbuffer UniformBlock {
    ComputeUniforms data;
}

[[vk::binding(1, 0)]] StructuredBuffer<float> input_data;
[[vk::binding(2, 0)]] RWStructuredBuffer<float> output_data;

[shader("compute")]
[numthreads(8, 4, 1)]
void computeMain(uint3 id : SV_DispatchThreadID) {
    if (id.x < data.count) {
        output_data[id.x] = input_data[id.x] * data.scale + data.bias;
    }
}
