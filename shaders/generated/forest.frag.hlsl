#pragma pack_matrix(column_major)
#ifdef SLANG_HLSL_ENABLE_NVAPI
#include "nvHLSLExtns.h"
#endif

#ifndef __DXC_VERSION_MAJOR
// warning X3557: loop doesn't seem to do anything, forcing loop to unroll
#pragma warning(disable : 3557)
#endif


#line 29 "shaders/forest.slang"
struct VertexOutput_0
{
    float4 position_0 : SV_POSITION;
    float3 color_0 : COLOR;
    float3 normal_0 : NORMAL;
    float3 to_camera_0 : TO_CAMERA;
    float4 fog_0 : FOG;
    float kind_0 : KIND;
    float height_0 : HEIGHT;
};


#line 71
float4 pixelMain(VertexOutput_0 input_0, bool front_0 : SV_IsFrontFace) : SV_TARGET
{

#line 72
    float3 n_0 = normalize(input_0.normal_0);

#line 72
    bool _S1;
    if(!front_0)
    {

#line 73
        _S1 = (input_0.kind_0) > 0.5f;

#line 73
    }
    else
    {

#line 73
        _S1 = false;

#line 73
    }

#line 73
    if(_S1)
    {

#line 73
        _S1 = (input_0.kind_0) < 1.5f;

#line 73
    }
    else
    {

#line 73
        _S1 = false;

#line 73
    }

#line 73
    float3 n_1;

#line 73
    if(_S1)
    {

#line 73
        n_1 = - n_0;

#line 73
    }
    else
    {

#line 73
        n_1 = n_0;

#line 73
    }

    float ndl_0 = dot(n_1, normalize(float3(0.44999998807907104f, 0.80000001192092896f, 0.34999999403953552f)));

    float lit_0 = smoothstep(-0.05000000074505806f, 0.11999999731779099f, ndl_0) * 0.60000002384185791f + smoothstep(0.44999998807907104f, 0.60000002384185791f, ndl_0) * 0.40000000596046448f;
    float3 sky_0 = float3(0.55000001192092896f, 0.69999998807907104f, 0.94999998807907104f);

    float3 ambient_0 = lerp(float3(0.34999999403953552f, 0.30000001192092896f, 0.20000000298023224f), sky_0, (float3)(n_1.y * 0.5f + 0.5f)) * 0.55000001192092896f;

#line 80
    float3 _S2 = input_0.color_0;

    if((input_0.kind_0) > 0.5f)
    {

#line 82
        _S1 = (input_0.kind_0) < 1.5f;

#line 82
    }
    else
    {

#line 82
        _S1 = false;

#line 82
    }

#line 82
    float3 base_0;

#line 82
    if(_S1)
    {

#line 82
        base_0 = lerp(_S2 * 0.55000001192092896f, _S2 * 1.35000002384185791f + float3(0.05000000074505806f, 0.07999999821186066f, 0.0f), (float3)input_0.height_0);

#line 82
    }
    else
    {
        if((input_0.kind_0) > 1.5f)
        {

#line 85
            base_0 = lerp(_S2 * 0.80000001192092896f, _S2 * 1.25f, (float3)input_0.height_0);

#line 85
        }
        else
        {

#line 85
            base_0 = _S2;

#line 85
        }

#line 82
    }

#line 94
    return float4(lerp(base_0 * (ambient_0 + float3(1.0f, 0.93000000715255737f, 0.77999997138977051f) * lit_0 * 0.85000002384185791f) + sky_0 * pow(1.0f - saturate(dot(n_1, normalize(input_0.to_camera_0))), 3.0f) * 0.11999999731779099f, input_0.fog_0.xyz, (float3)input_0.fog_0.w), 1.0f);
}

