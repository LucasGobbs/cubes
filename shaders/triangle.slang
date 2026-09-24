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

[shader("vertex")]
float4 vertexMain(uint vertexIndex : SV_VertexID)
{
    float4 position = float4(0);
    if (vertexIndex == 0) {
        position = float4(-.5, -.5, 0, 1);
    } else if (vertexIndex == 1) {
        position = float4(0, .5,0, 1);
    } else if (vertexIndex == 2) {
        position = float4(0.5, -.5, 0, 1);
    }

    return mul(u_data.mvp, position);
}

[shader("fragment")]
float4 pixelMain(float4 position) : SV_Target0
{
    return float4(1.0,0.0,0.0,1.0);
}
