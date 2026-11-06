#pragma pack_matrix(column_major)
#ifdef SLANG_HLSL_ENABLE_NVAPI
#include "nvHLSLExtns.h"
#endif

#ifndef __DXC_VERSION_MAJOR
// warning X3557: loop doesn't seem to do anything, forcing loop to unroll
#pragma warning(disable : 3557)
#endif


#line 11 "src/gbbfx/defaults/shaders/textured.slang"
Texture2D<float4 > tex_0 : register(t0);


#line 12
SamplerState tex_sampler_0 : register(s0);


#line 21
struct VertexOutput_0
{
    float4 position_0 : SV_POSITION;
    float4 color_0 : COLOR;
    float2 uv_0 : UV;
    float3 normal_0 : NORMAL;
};


#line 39
float4 pixelMain(VertexOutput_0 input_0) : SV_TARGET
{

#line 40
    float4 albedo_0 = tex_0.Sample(tex_sampler_0, input_0.uv_0) * input_0.color_0;

#line 40
    float3 _S1 = input_0.normal_0;


    if((dot(input_0.normal_0, input_0.normal_0)) < 9.99999993922529029e-09f)
    {

#line 43
        return albedo_0;
    }



    return float4(albedo_0.xyz * (float3(0.11999999731779099f, 0.11999999731779099f, 0.11999999731779099f) + max(dot(normalize(_S1), normalize(float3(0.40000000596046448f, 1.0f, 0.60000002384185791f))), 0.0f)), albedo_0.w);
}

