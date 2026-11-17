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
    float4x4 light_view_projection;
    float4 shadow_params; // x = enabled, y = depth bias, z = shadow map texel size
};

[[vk::binding(0, 0)]]
cbuffer UniformBlock {
    Uniforms data;
}

[[vk::binding(1, 0)]]
Texture2D shadow_map;
[[vk::binding(2, 0)]]
SamplerComparisonState shadow_sampler;

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
    float3 sun : SUN;
    float4 light_clip : LIGHT_CLIP;
    float4 shadow_params : SHADOW_PARAMS;
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
    float3 sun_dir = normalize(data.time.yzw);
    output.sun = sun_dir;
    // Aerial perspective: fog colour walks near (teal) -> mid (blue) -> far (violet-blue),
    // warm only in a narrow cone toward the sun, never white. Valley haze thickens low ground.
    float t = data.fog.a > 0.0 ? saturate(d / data.fog.a) : 0.0;
    float3 near_c = float3(0.50, 0.72, 0.74);
    float3 mid_c = float3(0.40, 0.60, 0.88);
    float3 far_c = float3(0.50, 0.55, 0.84);
    float3 fog_color = lerp(lerp(near_c, mid_c, smoothstep(0.0, 0.5, t)), far_c, smoothstep(0.4, 1.0, t));
    float toward_sun = pow(saturate(dot(-normalize(output.to_camera), sun_dir)), 8.0);
    fog_color = lerp(fog_color, float3(0.95, 0.70, 0.50), toward_sun * 0.55);
    float valley = saturate((30.0 - world.y) / 30.0) * 0.25;
    float fog_t = data.fog.a > 0.0 ? saturate((d - 0.10 * data.fog.a) / (0.90 * data.fog.a) + valley * t) : 0.0;
    output.fog = float4(fog_color, smoothstep(0.0, 1.0, pow(fog_t, 1.4)) * 0.92); // 0.92: far terrain keeps some colour
    output.kind = kind;
    output.light_clip = mul(data.light_view_projection, world);
    output.shadow_params = data.shadow_params;
    output.height = input.uv.x;
    return output;
}

// Sun shadow: 3x3 PCF over the depth map. Off or outside the map = lit.
float sun_shadow(float4 light_clip, float4 params) {
    if (params.x < 0.5) return 1.0;
    float3 ndc = light_clip.xyz / light_clip.w;
    float2 uv = float2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
    if (any(uv < 0.0) || any(uv > 1.0) || ndc.z > 1.0) return 1.0;
    float z = ndc.z - params.y;
    float sum = 0.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            sum += shadow_map.SampleCmpLevelZero(shadow_sampler, uv + float2(x, y) * params.z, z);
        }
    }
    return sum / 9.0;
}

[shader("fragment")]
float4 pixelMain(VertexOutput input, bool front : SV_IsFrontFace) : SV_Target0 {
    float3 n = normalize(input.normal);
    float3 sun = normalize(input.sun);
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
    float3 ambient = shade * 0.85;
    float3 sun_term = sun_color * 0.92;
    float shadow = sun_shadow(input.light_clip, input.shadow_params);
    float3 color = base * lerp(ambient, sun_term, lit * shadow);
    // Soft backlit glow on foliage and a faint sky rim.
    float rim = pow(1.0 - saturate(dot(n, normalize(input.to_camera))), 3.0);
    color += float3(0.55, 0.70, 0.95) * rim * 0.10 * (input.kind > 0.5 ? 1.0 : 0.4);
    return float4(lerp(color, input.fog.rgb, input.fog.a), 1.0);
}
