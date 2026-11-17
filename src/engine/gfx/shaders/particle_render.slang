// Particle billboards via vertex pulling: no vertex buffer. Each particle is
// a quad of 6 vertices, so instance = SV_VertexID / 6. SV_InstanceID is not
// used because the draw is issued with instance count 1.
//
// SDL_GPU vertex binding order: uniforms -> read-only storage buffers.

struct Particle {
    float3 position;
    float age;
    float3 velocity;
    float lifetime;
    float4 color;
};

struct RenderParams {
    float4x4 view_projection;
    float3 cam_right;
    float size_start;
    float3 cam_up;
    float size_end;
    float4 color_end;
    float fade_in;
    float3 _pad;
};

[[vk::binding(0, 0)]]
cbuffer UniformBlock {
    RenderParams params;
}

[[vk::binding(1, 0)]]
StructuredBuffer<Particle> particles;

struct VertexOutput {
    float4 position : SV_POSITION;
    float4 color : COLOR;
    float2 uv : UV;
};

[shader("vertex")]
VertexOutput vertexMain(uint vid : SV_VertexID) {
    uint instance = vid / 6;
    uint corner_id = vid % 6;
    // Two triangles covering the quad [-1,1]^2.
    float2 corners[6] = {
        float2(-1.0, -1.0), float2(1.0, -1.0), float2(1.0, 1.0),
        float2(-1.0, -1.0), float2(1.0, 1.0), float2(-1.0, 1.0),
    };
    float2 corner = corners[corner_id];

    Particle p = particles[instance];

    VertexOutput output;
    if (p.age >= p.lifetime) {
        // Dead: push outside every clip plane so nothing rasterizes. w = 0 would
        // hit the perspective divide, so keep w = 1.
        output.position = float4(2.0, 2.0, 2.0, 1.0);
        output.color = float4(0.0, 0.0, 0.0, 0.0);
        output.uv = corner;
        return output;
    }

    float t = p.age / p.lifetime;
    float size = lerp(params.size_start, params.size_end, t);
    float3 world = p.position + (params.cam_right * corner.x + params.cam_up * corner.y) * size * 0.5;

    float4 color = lerp(p.color, params.color_end, t);
    if (params.fade_in > 0.0) {
        color.a *= saturate(t / max(params.fade_in, 1e-4));
    }

    output.position = mul(params.view_projection, float4(world, 1.0));
    output.color = color;
    output.uv = corner;
    return output;
}

[shader("fragment")]
float4 pixelMain(VertexOutput input) : SV_Target0 {
    // Soft round sprite: squared falloff from the quad center.
    float a = saturate(1.0 - dot(input.uv, input.uv));
    a = a * a;
    return float4(input.color.rgb, input.color.a * a);
}
