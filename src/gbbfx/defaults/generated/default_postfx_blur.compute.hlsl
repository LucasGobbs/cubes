#pragma pack_matrix(column_major)
#ifdef SLANG_HLSL_ENABLE_NVAPI
#include "nvHLSLExtns.h"
#endif

#ifndef __DXC_VERSION_MAJOR
// warning X3557: loop doesn't seem to do anything, forcing loop to unroll
#pragma warning(disable : 3557)
#endif


#line 24 "src/gbbfx/defaults/shaders/postfx_blur.slang"
RWTexture2D<float4 > output_image_0 : register(u0);


#line 8
struct BlurParams_0
{
    float2 direction_0;
    int radius_0;
    float pad_0;
};

struct SLANG_ParameterGroup_UniformBlock_0
{
    BlurParams_0 params_0;
};


#line 15
cbuffer UniformBlock_0 : register(b0)
{
    SLANG_ParameterGroup_UniformBlock_0 UniformBlock_0;
}

Texture2D<float4 > input_image_0 : register(t0);

SamplerState input_sampler_0 : register(s0);


#line 28
[numthreads(8, 8, 1)]
void computeMain(uint2 tid_0 : SV_DispatchThreadID)
{

#line 30
    uint width_0;

#line 30
    uint height_0;
    output_image_0.GetDimensions(width_0, height_0);

#line 31
    bool _S1;
    if((tid_0.x) >= width_0)
    {

#line 32
        _S1 = true;

#line 32
    }
    else
    {

#line 32
        _S1 = (tid_0.y) >= height_0;

#line 32
    }

#line 32
    if(_S1)
    {

#line 32
        return;
    }
    float2 size_0 = float2(float(width_0), float(height_0));
    float2 _S2 = (float2(tid_0) + 0.5f) / size_0;
    float2 _S3 = 1.0f / size_0;

    float _S4 = float(max(UniformBlock_0.params_0.radius_0, int(1))) / 2.0f;
    float4 _S5 = float4((int4)int(0));

#line 39
    int i_0 = - UniformBlock_0.params_0.radius_0;

#line 39
    float4 sum_0 = _S5;

#line 39
    float weight_sum_0 = 0.0f;

    for(;;)
    {

#line 41
        if(i_0 <= (UniformBlock_0.params_0.radius_0))
        {
        }
        else
        {

#line 41
            break;
        }

#line 42
        float weight_0 = exp(- float(i_0 * i_0) / (2.0f * _S4 * _S4));
        float4 sum_1 = sum_0 + input_image_0.SampleLevel(input_sampler_0, _S2 + UniformBlock_0.params_0.direction_0 * float(i_0) * _S3, 0.0f) * weight_0;
        float weight_sum_1 = weight_sum_0 + weight_0;

#line 41
        i_0 = i_0 + int(1);

#line 41
        sum_0 = sum_1;

#line 41
        weight_sum_0 = weight_sum_1;

#line 41
    }

#line 46
    output_image_0[tid_0] = sum_0 / weight_sum_0;
    return;
}

