// Vertex-colored pipeline for SDL_GPU.
// Vertex layout matches the `Vertex` struct in src/main.odin and the
// GPUVertexAttribute locations 0-1 of the graphics pipeline.

[shader("vertex")]
float4 vertexMain(uint vertexIndex : SV_VertexID)
{
    if (vertexIndex == 0) {
        return float4(-.5, -.5, 0, 1);
    } else if (vertexIndex == 1) {
        return float4(0, .5, 0, 1);
    } else if (vertexIndex == 2) {
        return float4(0.5, -.5, 0, 1);
    }

    return float4(0);
}

[shader("fragment")]
float4 pixelMain(float4 position) : SV_Target0
{
    return float4(1.0,0.0,0.0,1.0);
}
