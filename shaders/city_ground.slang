// Ground quad under the city: samples the ground texture (city_ground_gen) and fogs per pixel like the buildings.

import "../src/engine/gfx/shaders/fog";
import constants;

struct Uniforms {
    float4x4 mvp;
    float4 camera_position;
    float4 fog; // rgb = linear fog color, a = view distance (<= 0 = off)
    float4 wet; // x = wetness 0..1, y = daylight 0..1
    float4 horizon; // rgb = linear sky band at the horizon, a unused
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
    float2 uv : UV;
    float3 to_camera : TO_CAMERA; // world space: the quad is already in world space
    float4 fog : FOG;
    float wetness : WETNESS; // 0 = dry (identical to the matte ground), 1 = soaked
    float daylight : DAYLIGHT; // 0 night .. 1 day: the road and the outskirts follow the day look
    float4 horizon : HORIZON; // rgb = linear horizon band, a = dusk weight 0..1
};

[shader("vertex")]
VertexOutput vertexMain(VertexInput input) {
    VertexOutput output;
    output.position = mul(data.mvp, float4(input.position, 1.0));
    output.uv = input.uv;
    output.to_camera = data.camera_position.xyz - input.position;
    output.fog = data.fog;
    output.wetness = data.wet.x;
    output.daylight = data.wet.y;
    output.horizon = float4(data.horizon.rgb, data.wet.z);
    return output;
}

[[vk::binding(1, 0)]]
Texture2D ground_texture;
[[vk::binding(2, 0)]]
SamplerState ground_sampler;

static const float LAMP_HEIGHT = 4.0; // lights.odin LAMP_HEIGHT: the mirror image of a lamp is this far above the puddle
static const float STREAK_UNITS = 8.0; // half length of the lamp smear along the view ray on the ground
static const float REFLECT_GAIN = 6.0; // lamp light reflected by a fully wet pool, linear, before fog
static const float3 SODIUM = float3(1.0, 0.62, 0.28); // sodium lamp colour in the reflection
static const float WET_DARKEN = 0.65; // wet asphalt albedo relative to dry
static const float ASPHALT_R = 0.13; // gen shader asphalt red at full lamp pool: divides the texel back to pool strength

// 1 inside the city texture, 0 in the outskirts the clamped texture would smear.
float inside_city(float2 uv) {
    return step(0.0, uv.x) * step(uv.x, 1.0) * step(0.0, uv.y) * step(uv.y, 1.0);
}

[shader("fragment")]
float4 pixelMain(VertexOutput input) : SV_Target0 {
    // The compute shader writes display-referred values into a UNORM texture; linearize for the sRGB swapchain.
    // Beyond the city (uv outside 0..1) the clamped texture would smear its edge row: draw dark outskirts instead.
    // Alpha is the puddle field (see city_ground_gen).
    float4 tex = ground_texture.Sample(ground_sampler, input.uv);
    float inside = inside_city(input.uv);
    // Outskirts: night black; by day the grey-blue ambient of the road, the fog colour only at full day (noon unchanged).
    float day_gate = smoothstep(0.0, 0.5, input.daylight);
    float3 ambient = float3(0.16, 0.19, 0.24);
    float lum = pow(input.daylight, 1.8); // dusk: the open ground darkens and warms toward the horizon colour
    float3 open_day = lerp(input.horizon.rgb * 0.15, ambient, lum);
    float3 outer = lerp(float3(0.0012, 0.0012, 0.002), lerp(open_day, input.fog.rgb, smoothstep(0.8, 1.0, input.daylight)), day_gate);
    float3 lit = lerp(outer, pow(tex.rgb, 2.2), inside);
    float wet = input.wetness;
    lit *= lerp(1.0, WET_DARKEN, wet); // wet asphalt is darker than dry
    // Day: the road reads as light grey-blue asphalt; night keeps the dark wet street.
    float3 day_road = float3(0.13, 0.15, 0.18) + dot(lit, float3(0.33, 0.33, 0.33)) * 4.0;
    lit = lerp(lit, day_road, input.daylight * inside);
    // Rim haze: within 300 units of the city edge the ground fades into the fog colour, so the edge is not a hard line.
    float2 edge = min(input.uv, 1.0 - input.uv) * float2(float(CITY_W), float(CITY_D));
    float rim = inside * (1.0 - smoothstep(0.0, 300.0, min(edge.x, edge.y))) * step(0.0, input.fog.a);
    lit = lerp(lit, lerp(input.fog.rgb, outer, day_gate), rim);

    // Puddles: the value-noise field clusters near 0.5, so stretch it around 0.5 before thresholding; wet lowers the cut.
    float field = saturate((tex.a - 0.5) * 4.0 + 0.5);
    float cut = lerp(0.8, 0.5, wet);
    float puddle = smoothstep(cut, cut + 0.08, field) * wet * inside * (1.0 - input.daylight);

    // Mirror image of the lamps: a lamp at height LAMP_HEIGHT shows in the puddle at p where the ray from the camera
    // through p meets it, i.e. p moved away from the lamp's ground point by LAMP_HEIGHT / cam height of the camera offset.
    // Its light is the lamp pool at that mirror point (sodium coloured), smeared along the view ray: the streak.
    float2 size = float2(float(CITY_W), float(CITY_D));
    float2 p = input.uv * size;
    float2 toward = input.to_camera.xz;
    float height = max(input.to_camera.y, 1.0);
    float2 mirror = p - (LAMP_HEIGHT / height) * toward;
    float2 dir = toward / max(length(toward), 1e-3);
    float light = 0;
    for (int t = -2; t <= 2; t++) {
        float2 q = mirror + dir * (float(t) * STREAK_UNITS);
        float2 uv = q / size;
        float pool = ground_texture.Sample(ground_sampler, uv).r / ASPHALT_R;
        light += pow(saturate(pool), 6.0) * inside_city(uv);
    }
    light /= 5.0;

    // Fresnel: grazing views (street level) reflect the horizon band; the lamp light rides on top.
    float cos_v = saturate(input.to_camera.y / max(length(input.to_camera), 1e-3));
    float fresnel = 0.02 + 0.98 * pow(1.0 - cos_v, 5.0);
    lit += puddle * fresnel * (SODIUM * light * REFLECT_GAIN + input.fog.rgb * 0.5);

    // Past the sky dome (radius 3500 in sky.odin) the ground is dropped, not drawn over it: the fogged ground reaches
    // black at the view distance and the sky shows below the horizon instead of a flat dark band.
    float dist = length(input.to_camera);
    if (input.fog.a > 0.0 && dist > 1.03 * input.fog.a) discard;
    // Dusk: the haze turns to the horizon band with distance, so the plane meets the sky glow instead of a brown step.
    float warm = input.horizon.a * 0.6 * saturate(dist / max(input.fog.a, 1e-3));
    float3 ember = min(input.horizon.rgb, float3(0.85, 0.85, 0.85)) * float3(1.0, 0.6, 0.6); // saturated orange, not cream
    float4 haze = float4(lerp(input.fog.rgb, ember, warm), input.fog.a);
    return float4(apply_fog_soft(lit, dist, haze), 1.0);
}
