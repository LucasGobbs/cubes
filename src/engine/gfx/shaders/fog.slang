// Distance fog ramp, the one definition shared by every shader that fogs. fog.rgb = linear fog colour,
// fog.a = view distance (<= 0 = off). Clear at 60% of the view distance, fully fogged at 100%.

float fog_factor(float dist, float4 fog) {
    return fog.a > 0.0 ? saturate((dist - 0.6 * fog.a) / (0.4 * fog.a)) : 0.0;
}

float3 apply_fog(float3 color, float dist, float4 fog) {
    return lerp(color, fog.rgb, fog_factor(dist, fog));
}
