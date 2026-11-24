// Cars: each lamp is a camera-facing billboard. The vertex shader slides its centre along the lane from the time
// uniform, so the CPU does no per-frame work and a car leaving one end of the map reappears at the other. The vertex
// colour.rg carries the corner in [-1,1]^2. Lamps are HDR, round soft glows: red when the car drives away from the
// eye, warm white when it comes toward it.

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
    [[vk::location(0)]] float3 position : POSITION; // lamp centre at the car's start pose
    [[vk::location(1)]] float4 color : COLOR; // rg = corner in [-1,1]^2
    [[vk::location(2)]] float2 uv : UV; // x = speed (units/s), y = start offset along the lane (units)
    [[vk::location(3)]] float3 normal : NORMAL; // xz = unit direction of travel
};

struct VertexOutput {
    float4 position : SV_POSITION;
    float2 corner : CORNER;
    float3 dir : DIR;
    float3 to_camera : TO_CAMERA; // world space
};

static const float LANE_LENGTH = 2048.0; // = CITY_SIZE in plan.odin: keep equal
static const float LAMP_WORLD_SIZE = 1.4; // full width in units
static const float LAMP_MIN_ANGULAR = 0.004; // full width grows with distance so distant lamps stay visible

[shader("vertex")]
VertexOutput vertexMain(VertexInput input) {
    float3 dir = float3(input.normal.x, 0.0, input.normal.z);
    float s0 = input.uv.y;
    float t = s0 + input.uv.x * data.time.x;
    float s = t - LANE_LENGTH * floor(t / LANE_LENGTH); // wraps at the map edge
    float3 centre = input.position + dir * (s - s0);

    float3 eye = data.camera_position.xyz;
    float3 to_eye = eye - centre;
    float dist = length(to_eye);
    float3 fwd = to_eye / max(dist, 1e-4);
    float3 right = normalize(cross(float3(0.0, 1.0, 0.0), fwd));
    float3 up = cross(fwd, right);
    float size = max(LAMP_WORLD_SIZE, dist * LAMP_MIN_ANGULAR) * 0.5;
    float3 world = centre + (right * input.color.r + up * input.color.g) * size;

    VertexOutput output;
    output.position = mul(data.mvp, float4(world, 1.0));
    output.corner = input.color.rg;
    output.dir = dir;
    output.to_camera = eye - centre;
    return output;
}

[shader("fragment")]
float4 pixelMain(VertexOutput input) : SV_Target0 {
    float r = length(input.corner);
    if (r > 1.0) discard;
    float a = exp(-r * r * 4.0);
    float core = smoothstep(0.35, 0.0, r);
    // dot(dir, centre - eye) > 0: the car is moving away, so we see its tail lamps.
    bool away = dot(input.dir, -input.to_camera) > 0.0;
    float3 tint = away ? float3(1.0, 0.08, 0.04) : float3(1.0, 0.92, 0.75);
    return float4(tint * (core * 1.6 + a * 1.0), 1.0);
}
