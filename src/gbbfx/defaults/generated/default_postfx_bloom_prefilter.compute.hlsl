#pragma pack_matrix(column_major)
#ifdef SLANG_HLSL_ENABLE_NVAPI
#include "nvHLSLExtns.h"
#endif

#ifndef __DXC_VERSION_MAJOR
// warning X3557: loop doesn't seem to do anything, forcing loop to unroll
#pragma warning(disable : 3557)
#endif


#line 23 "src/gbbfx/defaults/shaders/postfx_bloom_prefilter.slang"
RWTexture2D<float4 > output_image_0 : register(u0);


#line 19
Texture2D<float4 > input_image_0 : register(t0);

SamplerState input_sampler_0 : register(s0);


#line 7
struct PrefilterParams_0
{
    float threshold_0;
    float knee_0;
    float2 pad_0;
};

struct SLANG_ParameterGroup_UniformBlock_0
{
    PrefilterParams_0 params_0;
};


#line 14
cbuffer UniformBlock_0 : register(b0)
{
    SLANG_ParameterGroup_UniformBlock_0 UniformBlock_0;
}

#line 27
[numthreads(8, 8, 1)]
void computeMain(uint2 tid_0 : SV_DispatchThreadID)
{

#line 29
    uint width_0;

#line 29
    uint height_0;
    output_image_0.GetDimensions(width_0, height_0);

#line 30
    bool _S1;
    if((tid_0.x) >= width_0)
    {

#line 31
        _S1 = true;

#line 31
    }
    else
    {

#line 31
        _S1 = (tid_0.y) >= height_0;

#line 31
    }

#line 31
    if(_S1)
    {

#line 31
        return;
    }

    float3 c_0 = input_image_0.SampleLevel(input_sampler_0, (float2(tid_0) + 0.5f) / float2(float(width_0), float(height_0)), 0.0f).xyz;

    float _S2 = max(c_0.x, max(c_0.y, c_0.z));
    float soft_0 = clamp(_S2 - UniformBlock_0.params_0.threshold_0 + UniformBlock_0.params_0.knee_0, 0.0f, 2.0f * UniformBlock_0.params_0.knee_0);


    output_image_0[tid_0] = float4(c_0 * (max(soft_0 * soft_0 / (4.0f * UniformBlock_0.params_0.knee_0 + 0.00009999999747379f), _S2 - UniformBlock_0.params_0.threshold_0) / max(_S2, 0.00009999999747379f)), 1.0f);
    return;
}

