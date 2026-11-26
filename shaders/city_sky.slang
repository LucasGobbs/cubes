// Sky on the lampshade cylinder: the night sky texture (city_sky_gen, stars, clouds, night glow) cross-fades with a
// procedural day gradient and a sun disk + halo. Night is the texture alone; by day the texture fades out.
// Repeats in u, clamps in v.

struct Uniforms {
    float4x4 mvp;
    float4 horizon; // rgb = linear day colour at the horizon
    float4 zenith; // rgb = linear day colour overhead
    float4 sun; // xyz = unit direction to the sun, w = daylight (0 hides the sun)
    float4 params; // x = star_alpha (night texture visibility), yzw = colour the lampshade's lower band fades to (sRGB numbers, = fog)
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
    float4 color : COLOR;
    float2 uv : UV;
    float3 dir : DIR; // view direction on the cylinder (local = world, the cylinder follows the eye)
    float4 horizon : HORIZON;
    float4 zenith : ZENITH;
    float4 sun : SUN;
    float4 params : PARAMS;
};

[shader("vertex")]
VertexOutput vertexMain(VertexInput input) {
    VertexOutput output;
    output.position = mul(data.mvp, float4(input.position, 1.0));
    output.color = input.color;
    output.uv = input.uv;
    output.dir = input.position;
    output.horizon = data.horizon;
    output.zenith = data.zenith;
    output.sun = data.sun;
    output.params = data.params;
    return output;
}

[[vk::binding(1, 0)]]
Texture2D sky_texture;
[[vk::binding(2, 0)]]
SamplerState sky_sampler;

[shader("fragment")]
float4 pixelMain(VertexOutput input) : SV_Target0 {
    // The compute shader writes display-referred values into a UNORM texture; linearize for the sRGB swapchain.
    float4 texel = sky_texture.Sample(sky_sampler, input.uv);
    float3 night = pow(texel.rgb, 2.2);

    float3 dir = normalize(input.dir);
    float3 day = lerp(input.horizon.rgb, input.zenith.rgb, saturate(dir.y / 0.35));
    float sd = max(dot(dir, input.sun.xyz), 0.0);
    float3 sun_light = lerp(float3(1.0, 0.5, 0.2), float3(1.0, 0.92, 0.75), smoothstep(0.0, 0.3, input.sun.y)) * input.sun.w; // low sun: orange halo, not white
    day += sun_light * (pow(sd, 24.0) * 0.35 + pow(sd, 1500.0) * 4.0); // halo, then disk

    float3 glow = lerp(day, night, input.params.x);
    // Below the horizon and in a thin band above it the sky is the fog colour (linear, same as the ground fog), so
    // the ground meets the sky with no seam. Vertex colour.r is unused now; the ring data stays for the mesh.
    float haze = smoothstep(0.0, 0.08, dir.y);
    float3 band = min(lerp(input.params.yzw, glow, haze), float3(0.85, 0.85, 0.85)); // no channel above 0.85: keeps the dusk orange from blowing out to cream
    float k = lerp(0.6, 1.0, smoothstep(0.1, 0.9, input.sun.w)); // noon keeps full colour; dusk and night pull green/blue down
    band = float3(band.x, band.y * k, band.z * k);
    return float4(band, 1.0);
}
