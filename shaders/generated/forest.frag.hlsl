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


#line 72
float4 pixelMain(VertexOutput_0 input_0, bool front_0 : SV_IsFrontFace) : SV_TARGET
{

#line 73
    float3 n_0 = normalize(input_0.normal_0);


    float ndl_0 = dot(n_0, normalize(float3(0.44999998807907104f, 0.80000001192092896f, 0.34999999403953552f))) * 0.5f + 0.5f;
    float lit_0 = smoothstep(0.30000001192092896f, 0.55000001192092896f, ndl_0) * 0.5f + smoothstep(0.55000001192092896f, 0.85000002384185791f, ndl_0) * 0.5f;
    float3 shade_0 = float3(0.62000000476837158f, 0.74000000953674316f, 0.94999998807907104f);
    float3 sun_color_0 = float3(1.0f, 0.94999998807907104f, 0.80000001192092896f);

#line 79
    float3 _S1 = input_0.color_0;

#line 79
    bool _S2;

    if((input_0.kind_0) > 0.5f)
    {

#line 81
        _S2 = (input_0.kind_0) < 1.5f;

#line 81
    }
    else
    {

#line 81
        _S2 = false;

#line 81
    }

#line 81
    float3 base_0;

#line 81
    if(_S2)
    {

#line 81
        base_0 = lerp(_S1 * 0.92000001668930054f, _S1 * 1.08000004291534424f + float3(0.01999999955296516f, 0.03999999910593033f, -0.01999999955296516f), (float3)input_0.height_0);

#line 81
    }
    else
    {
        if((input_0.kind_0) > 1.5f)
        {

#line 84
            base_0 = _S1 * lerp(0.77999997138977051f, 1.1799999475479126f, input_0.height_0);

#line 84
        }
        else
        {

#line 84
            base_0 = _S1;

#line 84
        }

#line 81
    }

#line 88
    float3 color_1 = base_0 * lerp(shade_0 * 0.85000002384185791f, sun_color_0 * 0.92000001668930054f, (float3)lit_0);


    float3 _S3 = float3(0.55000001192092896f, 0.69999998807907104f, 0.94999998807907104f) * pow(1.0f - saturate(dot(n_0, normalize(input_0.to_camera_0))), 3.0f) * 0.10000000149011612f;

#line 91
    float _S4;

#line 91
    if((input_0.kind_0) > 0.5f)
    {

#line 91
        _S4 = 1.0f;

#line 91
    }
    else
    {

#line 91
        _S4 = 0.40000000596046448f;

#line 91
    }
    return float4(lerp(color_1 + _S3 * _S4, input_0.fog_0.xyz, (float3)input_0.fog_0.w), 1.0f);
}

