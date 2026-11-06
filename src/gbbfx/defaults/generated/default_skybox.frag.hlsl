#pragma pack_matrix(column_major)
#ifdef SLANG_HLSL_ENABLE_NVAPI
#include "nvHLSLExtns.h"
#endif

#ifndef __DXC_VERSION_MAJOR
// warning X3557: loop doesn't seem to do anything, forcing loop to unroll
#pragma warning(disable : 3557)
#endif


#line 19 "src/gbbfx/defaults/shaders/skybox.slang"
Texture2D<float4 > tex_0 : register(t0);


#line 20
SamplerState tex_sampler_0 : register(s0);


#line 26
struct VertexOutput_0
{
    float4 position_0 : SV_POSITION;
    float3 direction_0 : DIRECTION;
};


#line 42
float4 pixelMain(VertexOutput_0 input_0) : SV_TARGET
{

#line 43
    float3 d_0 = normalize(input_0.direction_0);

#line 48
    return tex_0.SampleLevel(tex_sampler_0, float2(atan2(d_0.z, d_0.x) / 6.28318548202514648f + 0.5f, acos(clamp(d_0.y, -1.0f, 1.0f)) / 3.14159274101257324f), 0.0f);
}

