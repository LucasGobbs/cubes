// Vertex-pulled textured pipeline: no vertex attributes. Vertices are read from
// a storage buffer by SV_VertexID. The Vertex layout is gfx.VertexData (48 bytes,
// tightly packed), spelled as scalars so std430 alignment cannot pad it.
// Otherwise identical to textured.slang.

struct Uniforms {
 float4x4 mvp;
 float4x4 normal_matrix;
};

[[vk::binding(0, 0)]]
cbuffer UniformBlock {
 Uniforms data;
}

struct Vertex {
 float px, py, pz;
 float r, g, b, a;
 float u, v;
 float nx, ny, nz;
};

[[vk::binding(3, 0)]]
StructuredBuffer<Vertex> vertices;

[[vk::binding(1, 0)]] Texture2D tex;
[[vk::binding(2, 0)]] SamplerState tex_sampler;

struct VertexOutput {
 float4 position : SV_POSITION;
 float4 color : COLOR;
 float2 uv : UV;
 float3 normal : NORMAL;
};

[shader("vertex")]
VertexOutput vertexMain(uint vid : SV_VertexID) {
 Vertex v = vertices[vid];
 float3 position = float3(v.px, v.py, v.pz);
 float3 normal = float3(v.nx, v.ny, v.nz);
 VertexOutput output;
 output.position = mul(data.mvp, float4(position, 1.0));
 output.color = float4(v.r, v.g, v.b, v.a);
 output.uv = float2(v.u, v.v);
 output.normal = mul(data.normal_matrix, float4(normal, 0.0)).xyz;
 return output;
}

[shader("fragment")]
float4 pixelMain(VertexOutput input) : SV_Target0 {
 float4 albedo = tex.Sample(tex_sampler, input.uv) * input.color;
 float3 n = input.normal;
 // zero normal = unlit (overlays, text, editor UI)
 if (dot(n, n) < 1e-8) return albedo;
 n = normalize(n);
 float3 light_dir = normalize(float3(0.4, 1.0, 0.6));
 float3 ambient = float3(0.12, 0.12, 0.12);
 float n_dot_l = max(dot(n, light_dir), 0.0);
 return float4(albedo.rgb * (ambient + n_dot_l), albedo.a);
}
