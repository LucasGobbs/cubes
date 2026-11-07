#pragma pack_matrix(column_major)
#ifdef SLANG_HLSL_ENABLE_NVAPI
#include "nvHLSLExtns.h"
#endif

#ifndef __DXC_VERSION_MAJOR
// warning X3557: loop doesn't seem to do anything, forcing loop to unroll
#pragma warning(disable : 3557)
#endif


#line 25 "src/gbbfx/defaults/shaders/textured_instanced.slang"
Texture2D<float4 > tex_0 : register(t1);


#line 26
SamplerState tex_sampler_0 : register(s0);


#line 35
struct VertexOutput_0
{
    float4 position_0 : SV_POSITION;
    float4 color_0 : COLOR;
    float2 uv_0 : UV;
    float3 normal_0 : NORMAL;
    float3 world_pos_0 : WORLD_POS;
    float3 eye_0 : EYE;
    float4 fog_0 : FOG;
};


#line 72
float4 pixelMain(VertexOutput_0 input_0) : SV_TARGET
{

#line 73
    float4 albedo_0 = tex_0.Sample(tex_sampler_0, input_0.uv_0) * input_0.color_0;

#line 73
    float3 _S1 = input_0.normal_0;


    if((dot(input_0.normal_0, input_0.normal_0)) < 9.99999993922529029e-09f)
    {

#line 76
        return albedo_0;
    }

#line 77
    float3 n_0 = normalize(_S1);
    float3 l_0 = normalize(float3(0.40000000596046448f, 1.0f, 0.60000002384185791f));
    float3 v_0 = normalize(input_0.eye_0 - input_0.world_pos_0);
    float _S2 = max(dot(n_0, l_0), 0.0f);

#line 80
    float specular_0;
    if(_S2 > 0.0f)
    {

#line 81
        specular_0 = pow(max(dot(reflect(- l_0, n_0), v_0), 0.0f), 32.0f);

#line 81
    }
    else
    {

#line 81
        specular_0 = 0.0f;

#line 81
    }


    return float4(lerp(albedo_0.xyz * (float3(0.11999999731779099f, 0.11999999731779099f, 0.11999999731779099f) + _S2) + specular_0 * 0.5f, input_0.fog_0.xyz, (float3)input_0.fog_0.w), albedo_0.w);
}

