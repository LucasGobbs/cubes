struct VertexInput {
    [[vk::location(0)]] float3 position : POSITION;
    [[vk::location(1)]] float4 color : COLOR;
};

struct VertexOutput {
    float4 position : SV_POSITION;
    float4 color : COLOR;
};

[shader("vertex")]
VertexOutput vertexMain(VertexInput input) {
    VertexOutput output;
    output.position = float4(input.position, 1.0);
    output.color = input.color;
    return output;
}

[shader("fragment")]
float4 pixelMain(VertexOutput input) : SV_Target0 {
    return input.color;
}
