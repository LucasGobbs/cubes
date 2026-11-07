#pragma pack_matrix(column_major)
#ifdef SLANG_HLSL_ENABLE_NVAPI
#include "nvHLSLExtns.h"
#endif

#ifndef __DXC_VERSION_MAJOR
// warning X3557: loop doesn't seem to do anything, forcing loop to unroll
#pragma warning(disable : 3557)
#endif


#line 27 "src/gbbfx/defaults/shaders/postfx_bloom_composite.slang"
RWTexture2D<float4 > output_image_0 : register(u0);


#line 19
Texture2D<float4 > scene_image_0 : register(t0);



SamplerState scene_sampler_0 : register(s0);


#line 21
Texture2D<float4 > bloom_image_0 : register(t1);



SamplerState bloom_sampler_0 : register(s1);


#line 8
struct CompositeParams_0
{
    float intensity_0;
    float pad0_0;
    float pad1_0;
    float pad2_0;
};


#line 14
struct SLANG_ParameterGroup_UniformBlock_0
{
    CompositeParams_0 params_0;
};


#line 14
cbuffer UniformBlock_0 : register(b0)
{
    SLANG_ParameterGroup_UniformBlock_0 UniformBlock_0;
}

#line 31
[numthreads(8, 8, 1)]
void computeMain(uint2 tid_0 : SV_DispatchThreadID)
{

#line 33
    uint width_0;

#line 33
    uint height_0;
    output_image_0.GetDimensions(width_0, height_0);

#line 34
    bool _S1;
    if((tid_0.x) >= width_0)
    {

#line 35
        _S1 = true;

#line 35
    }
    else
    {

#line 35
        _S1 = (tid_0.y) >= height_0;

#line 35
    }

#line 35
    if(_S1)
    {

#line 35
        return;
    }
    float2 uv_0 = (float2(tid_0) + 0.5f) / float2(float(width_0), float(height_0));


    output_image_0[tid_0] = float4(scene_image_0.SampleLevel(scene_sampler_0, uv_0, 0.0f).xyz + bloom_image_0.SampleLevel(bloom_sampler_0, uv_0, 0.0f).xyz * UniformBlock_0.params_0.intensity_0, 1.0f);
    return;
}

