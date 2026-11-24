// Streetlights: one camera-facing billboard per lamp. The vertex colour.rg carries the corner in [-1,1]^2; the vertex
// shader expands it in the camera's right/up around the lamp centre. The fragment is a round soft glow (bright core
// plus gaussian halo), HDR, drawn additively with no depth write so overlapping glows add up.

struct Uniforms {
    float4x4 mvp;
    float4 camera_position;
};

[[vk::binding(0, 0)]]
cbuffer UniformBlock {
    Uniforms data;
}

struct VertexInput {
    [[vk::location(0)]] float3 position : POSITION; // lamp centre
    [[vk::location(1)]] float4 color : COLOR; // rg = corner in [-1,1]^2
    [[vk::location(2)]] float2 uv : UV; // unused
    [[vk::location(3)]] float3 normal : NORMAL; // unused
};

struct VertexOutput {
    float4 position : SV_POSITION;
    float2 corner : CORNER;
};

static const float LAMP_WORLD_SIZE = 3.0; // full width in units
static const float LAMP_MIN_ANGULAR = 0.004; // full width grows with distance so distant lamps stay visible

[shader("vertex")]
VertexOutput vertexMain(VertexInput input) {
    float3 eye = data.camera_position.xyz;
    float3 to_eye = eye - input.position;
    float dist = length(to_eye);
    float3 fwd = to_eye / max(dist, 1e-4);
    float3 right = normalize(cross(float3(0.0, 1.0, 0.0), fwd));
    float3 up = cross(fwd, right);
    float size = max(LAMP_WORLD_SIZE, dist * LAMP_MIN_ANGULAR) * 0.5;
    float3 world = input.position + (right * input.color.r + up * input.color.g) * size;

    VertexOutput output;
    output.position = mul(data.mvp, float4(world, 1.0));
    output.corner = input.color.rg;
    return output;
}

[shader("fragment")]
float4 pixelMain(VertexOutput input) : SV_Target0 {
    float r = length(input.corner);
    if (r > 1.0) discard;
    float a = exp(-r * r * 4.0);
    float core = smoothstep(0.35, 0.0, r);
    float3 sodium = float3(1.0, 0.5, 0.15);
    return float4(sodium * (core * 1.6 + a * 1.0), 1.0);
}
