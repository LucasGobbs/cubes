#pragma pack_matrix(column_major)
#ifdef SLANG_HLSL_ENABLE_NVAPI
#include "nvHLSLExtns.h"
#endif

#ifndef __DXC_VERSION_MAJOR
// warning X3557: loop doesn't seem to do anything, forcing loop to unroll
#pragma warning(disable : 3557)
#endif


#line 9 "src/gbbfx/defaults/shaders/textured_instanced.slang"
struct Uniforms_0
{
    float4x4 view_projection_0;
    uint first_instance_0;
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

#line 15
struct _S1
{
    float4x4 _S2;
};

StructuredBuffer<_S1 > instance_transforms_0 : register(t0);


#line 31
struct VertexOutput_0
{
    float4 position_0 : SV_POSITION;
    float4 color_0 : COLOR;
    float2 uv_0 : UV;
};


#line 25
struct VertexInput_0
{
    float3 position_1 : POSITION;
    float4 color_1 : COLOR;
    float2 uv_1 : UV;
};


#line 38
VertexOutput_0 vertexMain(VertexInput_0 input_0, uint instance_id_0 : SV_InstanceID)
{
    VertexOutput_0 output_0;
    output_0.position_0 = mul(UniformBlock_0.data_0.view_projection_0, mul(instance_transforms_0.Load(instance_id_0 + UniformBlock_0.data_0.first_instance_0)._S2, float4(input_0.position_1, 1.0f)));
    output_0.color_0 = input_0.color_1;
    output_0.uv_0 = input_0.uv_1;
    return output_0;
}

