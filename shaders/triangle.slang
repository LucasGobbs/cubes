// Vertex-colored pipeline for SDL_GPU.
// Vertex layout matches the `Vertex` struct in src/main.odin and the
// GPUVertexAttribute locations 0-1 of the graphics pipeline.
struct Uniforms {
    float4x4 mvp;
};

[[vk::binding(0, 0)]]
cbuffer UniformBlock
{
    Uniforms u_data;
}

[[vk::binding(1, 0)]] Texture2D tex;
[[vk::binding(2, 0)]] SamplerState tex_sampler;

struct VertexInput {
    [[vk::location(0)]]float3 position : POSITION;
    [[vk::location(1)]]float4 color : COLOR;
    [[vk::location(2)]]float2 uv : UV;
};

struct VertexOutput {
    float4 position : SV_POSITION;
    float4 color : COLOR;
    float2 uv : UV;
};

[shader("vertex")]
VertexOutput vertexMain(VertexInput vertexInput)
{
    float4 position = float4(vertexInput.position, 1.0);

    VertexOutput output;
    output.position = mul(u_data.mvp, position);
    output.color = vertexInput.color;
    output.uv = vertexInput.uv;

    return output;
}

[shader("fragment")]
float4 pixelMain(VertexOutput vertexOutput) : SV_Target0
{
    float4 texColor = tex.Sample(tex_sampler, vertexOutput.uv);
    return texColor * vertexOutput.color;
}
