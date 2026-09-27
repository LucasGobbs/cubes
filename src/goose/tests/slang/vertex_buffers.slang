struct VertexInput {
    [[vk::location(0)]] float3 position : POSITION;
    [[vk::location(1)]] float3 normal : NORMAL;
    [[vk::location(2)]] float2 uv : TEXCOORD;
    [[vk::location(3)]] uint4 joints : JOINTS;
    [[vk::location(4)]] half2 weights : WEIGHTS;
    [[vk::location(5)]] uint16_t4 bone_indices : BONE_INDICES;
    [[vk::location(6)]] uint8_t4 flags : FLAGS;
};

struct VertexOutput {
    float4 position : SV_POSITION;
    float4 color : COLOR;
};

[shader("vertex")]
VertexOutput vertexMain(VertexInput input) {
    VertexOutput output;
    output.position = float4(input.position, 1.0);
    output.color = float4(abs(input.normal), input.uv.x + float(input.joints.x) * 0.0);
    return output;
}

[shader("fragment")]
float4 pixelMain(VertexOutput input) : SV_Target0 {
    return input.color;
}
