#pragma pack_matrix(column_major)
#ifdef SLANG_HLSL_ENABLE_NVAPI
#include "nvHLSLExtns.h"
#endif

#ifndef __DXC_VERSION_MAJOR
// warning X3557: loop doesn't seem to do anything, forcing loop to unroll
#pragma warning(disable : 3557)
#endif


#line 10 "src/gbbfx/defaults/shaders/skybox.slang"
struct Uniforms_0
{
    float4x4 inverse_view_projection_0;
};

struct SLANG_ParameterGroup_UniformBlock_0
{
    Uniforms_0 data_0;
};


#line 15
cbuffer UniformBlock_0 : register(b0)
{
    SLANG_ParameterGroup_UniformBlock_0 UniformBlock_0;
}

#line 26
struct VertexOutput_0
{
    float4 position_0 : SV_POSITION;
    float3 direction_0 : DIRECTION;
};


#line 22
struct VertexInput_0
{
    float3 position_1 : POSITION;
};


#line 32
VertexOutput_0 vertexMain(VertexInput_0 input_0)
{

#line 33
    VertexOutput_0 output_0;
    output_0.position_0 = float4(input_0.position_1.xy, 0.0f, 1.0f);
    output_0.direction_0 = mul(UniformBlock_0.data_0.inverse_view_projection_0, float4(input_0.position_1.xy, 0.0f, 1.0f)).xyz;
    return output_0;
}

