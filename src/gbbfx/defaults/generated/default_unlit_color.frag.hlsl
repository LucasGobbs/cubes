#pragma pack_matrix(column_major)
#ifdef SLANG_HLSL_ENABLE_NVAPI
#include "nvHLSLExtns.h"
#endif

#ifndef __DXC_VERSION_MAJOR
// warning X3557: loop doesn't seem to do anything, forcing loop to unroll
#pragma warning(disable : 3557)
#endif


#line 1 "src/gbbfx/defaults/shaders/unlit_color.slang"
struct Uniforms_0
{
    float4x4 mvp_0;
    float4 tint_0;
};

struct SLANG_ParameterGroup_UniformBlock_0
{
    Uniforms_0 data_0;
};


#line 7
cbuffer UniformBlock_0 : register(b0)
{
    SLANG_ParameterGroup_UniformBlock_0 UniformBlock_0;
}

#line 15
struct VertexOutput_0
{
    float4 position_0 : SV_POSITION;
};


#line 27
float4 pixelMain(VertexOutput_0 input_0) : SV_TARGET
{

#line 28
    return UniformBlock_0.data_0.tint_0;
}

