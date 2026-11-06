// Instanced textured pipeline with Phong shading. The
// per-instance model matrix comes from a storage buffer indexed by
// SV_InstanceID instead of a per-draw MVP uniform. One draw per
// (mesh, material) run instead of one draw per entity.
//
// SDL_GPU MSL binding order for vertex stage: uniform buffers first, then
// read-only storage buffers.

struct Uniforms {
    float4x4 view_projection;
 float3 camera_position;
    uint first_instance;
};

[[vk::binding(0, 0)]]
cbuffer UniformBlock {
    Uniforms data;
}

[[vk::binding(1, 0)]]
StructuredBuffer<float4x4> instance_transforms;

[[vk::binding(2, 0)]] Texture2D tex;
[[vk::binding(3, 0)]] SamplerState tex_sampler;

struct VertexInput {
    [[vk::location(0)]] float3 position : POSITION;
    [[vk::location(1)]] float4 color : COLOR;
    [[vk::location(2)]] float2 uv : UV;
 [[vk::location(3)]] float3 normal : NORMAL;
};

struct VertexOutput {
    float4 position : SV_POSITION;
    float4 color : COLOR;
    float2 uv : UV;
 float3 normal : NORMAL;
 float3 world_pos : WORLD_POS;
 float3 eye : EYE;
};

// Inverse transpose of the model's 3x3 part, via cofactor columns. Keeps
// normals perpendicular under non-uniform scale; sign(det) keeps them
// facing outward when the transform mirrors.
float3 world_normal(float4x4 m, float3 n) {
 float3 a = float3(m[0][0], m[1][0], m[2][0]);
 float3 b = float3(m[0][1], m[1][1], m[2][1]);
 float3 c = float3(m[0][2], m[1][2], m[2][2]);
 return sign(dot(a, cross(b, c))) * (n.x * cross(b, c) + n.y * cross(c, a) + n.z * cross(a, b));
}

[shader("vertex")]
VertexOutput vertexMain(VertexInput input, uint instance_id : SV_InstanceID) {
 float4x4 model = instance_transforms[instance_id + data.first_instance];
 float4 world = mul(model, float4(input.position, 1.0));
 VertexOutput output;
 output.position = mul(data.view_projection, world);
 output.color = input.color;
 output.uv = input.uv;
 output.world_pos = world.xyz;
 output.normal = world_normal(model, input.normal);
 output.eye = data.camera_position;
 return output;
}

[shader("fragment")]
float4 pixelMain(VertexOutput input) : SV_Target0 {
 float4 albedo = tex.Sample(tex_sampler, input.uv) * input.color;
 float3 n = input.normal;
 // zero normal = unlit (overlays, text, editor UI)
 if (dot(n, n) < 1e-8) return albedo;
 n = normalize(n);
 float3 l = normalize(float3(0.4, 1.0, 0.6));
 float3 v = normalize(input.eye - input.world_pos);
 float diffuse = max(dot(n, l), 0.0);
 float specular = diffuse > 0.0 ? pow(max(dot(reflect(-l, n), v), 0.0), 32.0) : 0.0;
 float3 ambient = float3(0.12, 0.12, 0.12);
 return float4(albedo.rgb * (ambient + diffuse) + specular * 0.5, albedo.a);
}
