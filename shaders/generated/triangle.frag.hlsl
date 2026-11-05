#pragma pack_matrix(column_major)
#ifdef SLANG_HLSL_ENABLE_NVAPI
#include "nvHLSLExtns.h"
#endif

#ifndef __DXC_VERSION_MAJOR
// warning X3557: loop doesn't seem to do anything, forcing loop to unroll
#pragma warning(disable : 3557)
#endif


#line 14 "shaders/triangle.slang"
Texture2D<float4 > tex_0 : register(t0);


#line 15
SamplerState tex_sampler_0 : register(s0);


#line 23
struct VertexOutput_0
{
    float4 position_0 : SV_POSITION;
    float4 color_0 : COLOR;
    float2 uv_0 : UV;
};


#line 43
float4 pixelMain(VertexOutput_0 vertexOutput_0) : SV_TARGET
{

    return tex_0.Sample(tex_sampler_0, vertexOutput_0.uv_0) * vertexOutput_0.color_0;
}

