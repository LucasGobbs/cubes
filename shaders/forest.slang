// Toon forest: one shader for terrain, tree trunks/canopies, rocks and grass.
// Meshes are baked in world space per chunk, so there is no per-instance data.
// Vertex contract (gbbfx.VertexData):
//   position = world position, color.rgb = base color,
//   uv.x = wind weight (0 rooted .. 1 free tip), uv.y = kind:
//   0 solid, 1 grass blade, 2 foliage (canopy sway), normal = shading normal.
// Wind is evaluated here only; the CPU never touches the meshes per frame.

struct Uniforms {
    float4x4 view_projection;
    float4x4 model;
    float4 camera_position;
    float4 time; // x = seconds
    float4 fog; // rgb = linear fog color, a = view distance (<= 0 = off)
};

[[vk::binding(0, 0)]]
cbuffer UniformBlock {
    Uniforms data;
}

struct VertexInput {
    [[vk::location(0)]] float3 position : POSITION;
    [[vk::location(1)]] float4 color : COLOR;
    [[vk::location(2)]] float2 uv : UV;
    [[vk::location(3)]] float3 normal : NORMAL;
};

struct VertexOutput {
    float4 position : SV_POSITION;
    float3 color : COLOR;
    float3 normal : NORMAL;
    float3 to_camera : TO_CAMERA;
    float4 fog : FOG;
    float kind : KIND;
    float height : HEIGHT;
};

// Travelling gust: a broad wave crossing the field plus a faster flutter.
float2 wind_offset(float3 world, float t, float weight, float kind) {
    float gust = sin(dot(world.xz, float2(0.11, 0.07)) + t * 1.3) * 0.5 + 0.5;
    float flutter = sin(dot(world.xz, float2(0.9, 0.7)) + t * 3.1 + world.x * 0.3);
    float amp = kind < 1.5 ? 0.35 : 0.12; // grass leans, canopies barely move
    float2 dir = normalize(float2(1.0, 0.45));
    return dir * (gust * 0.8 + flutter * 0.15) * amp * weight * weight;
}

[shader("vertex")]
VertexOutput vertexMain(VertexInput input) {
    float4 world = mul(data.model, float4(input.position, 1.0));
    float kind = input.uv.y;
    if (kind > 0.5) {
        float2 w = wind_offset(world.xyz, data.time.x, input.uv.x, kind);
        world.x += w.x;
        world.z += w.y;
        if (kind < 1.5) world.y -= length(w) * 0.35 * input.uv.x; // bent blade drops
    }
    VertexOutput output;
    output.position = mul(data.view_projection, world);
    output.color = input.color.rgb;
    output.normal = normalize(mul((float3x3)data.model, input.normal));
    output.to_camera = data.camera_position.xyz - world.xyz;
    float d = length(output.to_camera);
    float fog_t = data.fog.a > 0.0 ? saturate((d - 0.15 * data.fog.a) / (0.85 * data.fog.a)) : 0.0;
    output.fog = float4(data.fog.rgb, pow(fog_t, 1.6)); // gentle start, hazy far mountains
    output.kind = kind;
    output.height = input.uv.x;
    return output;
}

[shader("fragment")]
float4 pixelMain(VertexOutput input, bool front : SV_IsFrontFace) : SV_Target0 {
    float3 n = normalize(input.normal);
    float3 sun = normalize(float3(0.45, 0.8, 0.35));
    // Half-lambert wrap + soft toon steps: shadows stay bright and tinted, never black.
    float ndl = dot(n, sun) * 0.5 + 0.5;
    float lit = smoothstep(0.30, 0.55, ndl) * 0.5 + smoothstep(0.55, 0.85, ndl) * 0.5;
    float3 shade = float3(0.62, 0.74, 0.95); // cool sky-lit shadow colour
    float3 sun_color = float3(1.0, 0.95, 0.80);
    float3 base = input.color;
    if (input.kind > 0.5 && input.kind < 1.5) {
        // Root matches the terrain underneath; tips go lighter and yellower.
        base = lerp(base * 0.92, base * 1.08 + float3(0.02, 0.04, -0.02), input.height);
    } else if (input.kind > 1.5) {
        // Crowns: darker underneath, sun-bleached on top.
        base = base * lerp(0.78, 1.18, input.height);
    }
    float3 color = base * lerp(shade * 0.85, sun_color * 0.92, lit);
    // Soft backlit glow on foliage and a faint sky rim.
    float rim = pow(1.0 - saturate(dot(n, normalize(input.to_camera))), 3.0);
    color += float3(0.55, 0.70, 0.95) * rim * 0.10 * (input.kind > 0.5 ? 1.0 : 0.4);
    return float4(lerp(color, input.fog.rgb, input.fog.a), 1.0);
}
