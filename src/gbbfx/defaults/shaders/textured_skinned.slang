// Skinned textured pipeline with Phong shading. Vertices are linear-blend
// skinned in mesh-local space with the instance's palette, then placed by
// the instance transform. Per instance, both buffers are indexed by
// SV_InstanceID + first_instance: instance_transforms[i] is the entity
// transform and palettes[i * MAX_JOINTS + j] is joint j's skin matrix.
// Fragment matches textured_instanced.slang.
//
// SDL_GPU MSL binding order for vertex stage: uniform buffers first, then
// read-only storage buffers in declaration order (instance_transforms, palettes).

struct Uniforms {
    float4x4 view_projection;
    float3 camera_position;
    uint first_instance;
    // rgb = linear fog color, a = view distance (<= 0 = fog off)
    float4 fog;
};

static const uint MAX_JOINTS = 128;

[[vk::binding(0, 0)]]
cbuffer UniformBlock {
    Uniforms data;
}

[[vk::binding(1, 0)]]
StructuredBuffer<float4x4> instance_transforms;

[[vk::binding(2, 0)]]
StructuredBuffer<float4x4> palettes;

[[vk::binding(3, 0)]] Texture2D tex;
[[vk::binding(4, 0)]] SamplerState tex_sampler;

struct VertexInput {
    [[vk::location(0)]] float3 position : POSITION;
    [[vk::location(1)]] float3 normal : NORMAL;
    [[vk::location(2)]] float2 uv : UV;
    [[vk::location(3)]] vector<uint16_t, 4> joints : JOINTS;
    [[vk::location(4)]] float4 weights : WEIGHTS;
};

struct VertexOutput {
    float4 position : SV_POSITION;
    float4 color : COLOR;
    float2 uv : UV;
    float3 normal : NORMAL;
    float3 world_pos : WORLD_POS;
    float3 eye : EYE;
    float4 fog : FOG;
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
    uint index = instance_id + data.first_instance;
    float4x4 model = instance_transforms[index];
    uint palette_base = index * MAX_JOINTS;
    // Weights are normalized at import, so the blend is a convex combination.
    float4x4 skin = input.weights.x * palettes[palette_base + uint(input.joints.x)]
        + input.weights.y * palettes[palette_base + uint(input.joints.y)]
        + input.weights.z * palettes[palette_base + uint(input.joints.z)]
        + input.weights.w * palettes[palette_base + uint(input.joints.w)];
    float4 local = mul(skin, float4(input.position, 1.0));
    float4 world = mul(model, local);
    VertexOutput output;
    output.position = mul(data.view_projection, world);
    output.color = float4(1.0, 1.0, 1.0, 1.0);
    output.uv = input.uv;
    output.world_pos = world.xyz;
    output.normal = world_normal(model, normalize(mul((float3x3)skin, input.normal)));
    output.eye = data.camera_position;
    float d = distance(data.camera_position, world.xyz);
    output.fog = float4(data.fog.rgb, data.fog.a > 0.0 ? saturate((d - 0.6 * data.fog.a) / (0.4 * data.fog.a)) : 0.0);
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
    float3 lit = albedo.rgb * (ambient + diffuse) + specular * 0.5;
    return float4(lerp(lit, input.fog.rgb, input.fog.a), albedo.a);
}
