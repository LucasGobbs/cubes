#pragma pack_matrix(column_major)
#ifdef SLANG_HLSL_ENABLE_NVAPI
#include "nvHLSLExtns.h"
#endif

#ifndef __DXC_VERSION_MAJOR
// warning X3557: loop doesn't seem to do anything, forcing loop to unroll
#pragma warning(disable : 3557)
#endif


#line 1 "shaders/unlit_color.slang"
struct UnlitUniforms_0
{
    float4x4 mvp_0;
    float4 tint_0;
};

struct SLANG_ParameterGroup_UniformBlock_0
{
    UnlitUniforms_0 data_0;
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


#line 11
struct VertexInput_0
{
    float3 position_1 : POSITION;
};


#line 20
VertexOutput_0 vertexMain(VertexInput_0 input_0)
{

#line 21
    VertexOutput_0 output_0;
    output_0.position_0 = mul(UniformBlock_0.data_0.mvp_0, float4(input_0.position_1, 1.0f));
    return output_0;
}

