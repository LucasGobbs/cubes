#pragma pack_matrix(column_major)
#ifdef SLANG_HLSL_ENABLE_NVAPI
#include "nvHLSLExtns.h"
#endif

#ifndef __DXC_VERSION_MAJOR
// warning X3557: loop doesn't seem to do anything, forcing loop to unroll
#pragma warning(disable : 3557)
#endif


#line 12 "shaders/blur.slang"
RWTexture2D<float4 > output_image_0 : register(u0);


#line 8
Texture2D<float4 > input_image_0 : register(t0);

SamplerState input_sampler_0 : register(s0);


#line 16
[numthreads(8, 8, 1)]
void computeMain(uint2 tid_0 : SV_DispatchThreadID)
{

#line 18
    uint width_0;

#line 18
    uint height_0;
    output_image_0.GetDimensions(width_0, height_0);

#line 19
    bool _S1;
    if((tid_0.x) >= width_0)
    {

#line 20
        _S1 = true;

#line 20
    }
    else
    {

#line 20
        _S1 = (tid_0.y) >= height_0;

#line 20
    }

#line 20
    if(_S1)
    {

#line 20
        return;
    }
    float2 size_0 = float2(float(width_0), float(height_0));
    float2 _S2 = (float2(tid_0) + 0.5f) / size_0;
    float2 _S3 = 1.0f / size_0;

    float4 _S4 = float4((int4)int(0));

#line 26
    int y_0 = int(-2);

#line 26
    float4 sum_0 = _S4;
    for(;;)
    {

#line 27
        if(y_0 <= int(2))
        {
        }
        else
        {

#line 27
            break;
        }

#line 27
        int x_0 = int(-2);
        for(;;)
        {

#line 28
            if(x_0 <= int(2))
            {
            }
            else
            {

#line 28
                break;
            }

#line 29
            float4 sum_1 = sum_0 + input_image_0.SampleLevel(input_sampler_0, _S2 + float2(float(x_0), float(y_0)) * _S3, 0.0f);

#line 28
            x_0 = x_0 + int(1);

#line 28
            sum_0 = sum_1;

#line 28
        }

#line 27
        y_0 = y_0 + int(1);

#line 27
    }

#line 32
    output_image_0[tid_0] = sum_0 / 25.0f;
    return;
}

