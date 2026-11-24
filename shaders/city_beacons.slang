// Aviation beacons and roof lights: one camera-facing billboard per light, as city_lights.slang. Per-light data:
// color.rg = corner in [-1,1]^2, color.b = blink phase in [0,1), color.a = blink period in seconds, uv.x = 1 to blink
// (0 steady), uv.y = full width in units, normal = HDR tint. Blinking lights pulse on for about a third of each period
// and sit dim otherwise; the pulse runs on the GPU from time, so the CPU never rewrites the mesh.

struct Uniforms {
    float4x4 mvp;
    float4 camera_position;
    float4 time; // x = seconds
};

[[vk::binding(0, 0)]]
cbuffer UniformBlock {
    Uniforms data;
}

struct VertexInput {
    [[vk::location(0)]] float3 position : POSITION; // light centre
    [[vk::location(1)]] float4 color : COLOR; // rg = corner, b = phase, a = period
    [[vk::location(2)]] float2 uv : UV; // x = blink flag, y = width
    [[vk::location(3)]] float3 normal : NORMAL; // HDR tint
};

struct VertexOutput {
    float4 position : SV_POSITION;
    float2 corner : CORNER;
    float3 glow : GLOW; // tint times brightness, constant over the quad
};

static const float BEACON_MIN_ANGULAR = 0.003; // full width grows with distance so distant lights stay visible

[shader("vertex")]
VertexOutput vertexMain(VertexInput input) {
    float3 eye = data.camera_position.xyz;
    float3 to_eye = eye - input.position;
    float dist = length(to_eye);
    float3 fwd = to_eye / max(dist, 1e-4);
    float3 right = normalize(cross(float3(0.0, 1.0, 0.0), fwd));
    float3 up = cross(fwd, right);
    float size = max(input.uv.y, dist * BEACON_MIN_ANGULAR) * 0.5;
    float3 world = input.position + (right * input.color.r + up * input.color.g) * size;

    float p = frac(data.time.x / input.color.a + input.color.b);
    float on = smoothstep(0.0, 0.06, p) * (1.0 - smoothstep(0.28, 0.35, p));
    float brightness = input.uv.x > 0.5 ? lerp(0.1, 1.0, on) : 1.0;

    VertexOutput output;
    output.position = mul(data.mvp, float4(world, 1.0));
    output.corner = input.color.rg;
    output.glow = input.normal * brightness;
    return output;
}

[shader("fragment")]
float4 pixelMain(VertexOutput input) : SV_Target0 {
    float r = length(input.corner);
    if (r > 1.0) discard;
    float a = exp(-r * r * 4.0);
    float core = smoothstep(0.35, 0.0, r);
    return float4(input.glow * (core * 1.6 + a * 1.0), 1.0);
}
