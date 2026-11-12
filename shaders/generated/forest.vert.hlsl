#pragma pack_matrix(column_major)
#ifdef SLANG_HLSL_ENABLE_NVAPI
#include "nvHLSLExtns.h"
#endif

#ifndef __DXC_VERSION_MAJOR
// warning X3557: loop doesn't seem to do anything, forcing loop to unroll
#pragma warning(disable : 3557)
#endif


#line 9 "shaders/forest.slang"
struct Uniforms_0
{
    float4x4 view_projection_0;
    float4x4 model_0;
    float4 camera_position_0;
    float4 time_0;
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

#line 41
float2 wind_offset_0(float3 world_0, float t_0, float weight_0, float kind_0)
{

#line 42
    float2 _S1 = world_0.xz;

#line 42
    float gust_0 = sin(dot(_S1, float2(0.10999999940395355f, 0.07000000029802322f)) + t_0 * 1.29999995231628418f) * 0.5f + 0.5f;
    float flutter_0 = sin(dot(_S1, float2(0.89999997615814209f, 0.69999998807907104f)) + t_0 * 3.09999990463256836f + world_0.x * 0.30000001192092896f);

#line 43
    float amp_0;
    if(kind_0 < 1.5f)
    {

#line 44
        amp_0 = 0.34999999403953552f;

#line 44
    }
    else
    {

#line 44
        amp_0 = 0.11999999731779099f;

#line 44
    }

    return normalize(float2(1.0f, 0.44999998807907104f)) * (gust_0 * 0.80000001192092896f + flutter_0 * 0.15000000596046448f) * amp_0 * weight_0 * weight_0;
}


#line 29
struct VertexOutput_0
{
    float4 position_0 : SV_POSITION;
    float3 color_0 : COLOR;
    float3 normal_0 : NORMAL;
    float3 to_camera_0 : TO_CAMERA;
    float4 fog_1 : FOG;
    float kind_1 : KIND;
    float height_0 : HEIGHT;
    float3 sun_0 : SUN;
};


#line 22
struct VertexInput_0
{
    float3 position_1 : POSITION;
    float4 color_1 : COLOR;
    float2 uv_0 : UV;
    float3 normal_1 : NORMAL;
};


#line 50
VertexOutput_0 vertexMain(VertexInput_0 input_0)
{

#line 51
    float4 world_1 = mul(UniformBlock_0.data_0.model_0, float4(input_0.position_1, 1.0f));
    float kind_2 = input_0.uv_0.y;
    if(kind_2 > 0.5f)
    {

#line 54
        float2 w_0 = wind_offset_0(world_1.xyz, UniformBlock_0.data_0.time_0.x, input_0.uv_0.x, kind_2);
        world_1[int(0)] = world_1[int(0)] + w_0.x;
        world_1[int(2)] = world_1[int(2)] + w_0.y;
        if(kind_2 < 1.5f)
        {

#line 57
            world_1[int(1)] = world_1[int(1)] - length(w_0) * 0.34999999403953552f * input_0.uv_0.x;

#line 57
        }

#line 53
    }

#line 59
    VertexOutput_0 output_0;
    output_0.position_0 = mul(UniformBlock_0.data_0.view_projection_0, world_1);
    output_0.color_0 = input_0.color_1.xyz;
    output_0.normal_0 = normalize(mul(float3x3(UniformBlock_0.data_0.model_0[int(0)].xyz, UniformBlock_0.data_0.model_0[int(1)].xyz, UniformBlock_0.data_0.model_0[int(2)].xyz), input_0.normal_1));
    float3 _S2 = UniformBlock_0.data_0.camera_position_0.xyz - world_1.xyz;

#line 63
    output_0.to_camera_0 = _S2;
    float d_0 = length(_S2);
    float3 sun_dir_0 = normalize(UniformBlock_0.data_0.time_0.yzw);
    output_0.sun_0 = sun_dir_0;

#line 66
    float t_1;


    if((UniformBlock_0.data_0.fog_0.w) > 0.0f)
    {

#line 69
        t_1 = saturate(d_0 / UniformBlock_0.data_0.fog_0.w);

#line 69
    }
    else
    {

#line 69
        t_1 = 0.0f;

#line 69
    }

#line 75
    float3 fog_color_0 = lerp(lerp(lerp(float3(0.5f, 0.72000002861022949f, 0.74000000953674316f), float3(0.40000000596046448f, 0.60000002384185791f, 0.87999999523162842f), (float3)smoothstep(0.0f, 0.5f, t_1)), float3(0.5f, 0.55000001192092896f, 0.8399999737739563f), (float3)smoothstep(0.40000000596046448f, 1.0f, t_1)), float3(0.94999998807907104f, 0.69999998807907104f, 0.5f), (float3)(pow(saturate(dot(- normalize(output_0.to_camera_0), sun_dir_0)), 8.0f) * 0.55000001192092896f));
    float valley_0 = saturate((30.0f - world_1.y) / 30.0f) * 0.25f;

#line 76
    float fog_t_0;
    if((UniformBlock_0.data_0.fog_0.w) > 0.0f)
    {

#line 77
        fog_t_0 = saturate((d_0 - 0.10000000149011612f * UniformBlock_0.data_0.fog_0.w) / (0.89999997615814209f * UniformBlock_0.data_0.fog_0.w) + valley_0 * t_1);

#line 77
    }
    else
    {

#line 77
        fog_t_0 = 0.0f;

#line 77
    }
    output_0.fog_1 = float4(fog_color_0, smoothstep(0.0f, 1.0f, pow(fog_t_0, 1.39999997615814209f)) * 0.92000001668930054f);
    output_0.kind_1 = kind_2;
    output_0.height_0 = input_0.uv_0.x;
    return output_0;
}

