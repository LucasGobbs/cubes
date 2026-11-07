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
    float3 camera_position_0;
    uint first_instance_0;
    float4 fog_0;
};


struct SLANG_ParameterGroup_UniformBlock_0
{
    Uniforms_0 data_0;
};


#line 18
cbuffer UniformBlock_0 : register(b0)
{
    SLANG_ParameterGroup_UniformBlock_0 UniformBlock_0;
}

#line 18
struct _S1
{
    float4x4 _S2;
};

StructuredBuffer<_S1 > instance_transforms_0 : register(t0);


#line 48
float3 world_normal_0(float4x4 m_0, float3 n_0)
{

#line 49
    float3 a_0 = float3(m_0[int(0)][int(0)], m_0[int(1)][int(0)], m_0[int(2)][int(0)]);
    float3 b_0 = float3(m_0[int(0)][int(1)], m_0[int(1)][int(1)], m_0[int(2)][int(1)]);
    float3 c_0 = float3(m_0[int(0)][int(2)], m_0[int(1)][int(2)], m_0[int(2)][int(2)]);
    float3 _S3 = cross(b_0, c_0);

#line 52
    return float(sign(dot(a_0, _S3))) * (n_0.x * _S3 + n_0.y * cross(c_0, a_0) + n_0.z * cross(a_0, b_0));
}


#line 35
struct VertexOutput_0
{
    float4 position_0 : SV_POSITION;
    float4 color_0 : COLOR;
    float2 uv_0 : UV;
    float3 normal_0 : NORMAL;
    float3 world_pos_0 : WORLD_POS;
    float3 eye_0 : EYE;
    float4 fog_1 : FOG;
};


#line 28
struct VertexInput_0
{
    float3 position_1 : POSITION;
    float4 color_1 : COLOR;
    float2 uv_1 : UV;
    float3 normal_1 : NORMAL;
};


#line 56
VertexOutput_0 vertexMain(VertexInput_0 input_0, uint instance_id_0 : SV_InstanceID)
{

#line 57
    _S1 model_0 = instance_transforms_0.Load(instance_id_0 + UniformBlock_0.data_0.first_instance_0);
    float4 world_0 = mul(model_0._S2, float4(input_0.position_1, 1.0f));
    VertexOutput_0 output_0;
    output_0.position_0 = mul(UniformBlock_0.data_0.view_projection_0, world_0);
    output_0.color_0 = input_0.color_1;
    output_0.uv_0 = input_0.uv_1;
    float3 _S4 = world_0.xyz;

#line 63
    output_0.world_pos_0 = _S4;
    output_0.normal_0 = world_normal_0(model_0._S2, input_0.normal_1);
    output_0.eye_0 = UniformBlock_0.data_0.camera_position_0;
    float d_0 = distance(UniformBlock_0.data_0.camera_position_0, _S4);
    float3 _S5 = UniformBlock_0.data_0.fog_0.xyz;

#line 67
    float _S6;

#line 67
    if((UniformBlock_0.data_0.fog_0.w) > 0.0f)
    {

#line 67
        _S6 = saturate((d_0 - 0.60000002384185791f * UniformBlock_0.data_0.fog_0.w) / (0.40000000596046448f * UniformBlock_0.data_0.fog_0.w));

#line 67
    }
    else
    {

#line 67
        _S6 = 0.0f;

#line 67
    }

#line 67
    output_0.fog_1 = float4(_S5, _S6);
    return output_0;
}

