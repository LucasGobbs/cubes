#pragma pack_matrix(column_major)
#ifdef SLANG_HLSL_ENABLE_NVAPI
#include "nvHLSLExtns.h"
#endif

#ifndef __DXC_VERSION_MAJOR
// warning X3557: loop doesn't seem to do anything, forcing loop to unroll
#pragma warning(disable : 3557)
#endif


#line 1 "src/gbbfx/defaults/shaders/textured.slang"
struct Uniforms_0
{
    float4x4 mvp_0;
    float4x4 normal_matrix_0;
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

#line 21
struct VertexOutput_0
{
    float4 position_0 : SV_POSITION;
    float4 color_0 : COLOR;
    float2 uv_0 : UV;
    float3 normal_0 : NORMAL;
};


#line 14
struct VertexInput_0
{
    float3 position_1 : POSITION;
    float4 color_1 : COLOR;
    float2 uv_1 : UV;
    float3 normal_1 : NORMAL;
};


#line 29
VertexOutput_0 vertexMain(VertexInput_0 input_0)
{

#line 30
    VertexOutput_0 output_0;
    output_0.position_0 = mul(UniformBlock_0.data_0.mvp_0, float4(input_0.position_1, 1.0f));
    output_0.color_0 = input_0.color_1;
    output_0.uv_0 = input_0.uv_1;
    output_0.normal_0 = mul(UniformBlock_0.data_0.normal_matrix_0, float4(input_0.normal_1, 0.0f)).xyz;
    return output_0;
}

