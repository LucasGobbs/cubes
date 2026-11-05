#pragma pack_matrix(column_major)
#ifdef SLANG_HLSL_ENABLE_NVAPI
#include "nvHLSLExtns.h"
#endif

#ifndef __DXC_VERSION_MAJOR
// warning X3557: loop doesn't seem to do anything, forcing loop to unroll
#pragma warning(disable : 3557)
#endif


#line 11 "shaders/compute.slang"
RWStructuredBuffer<float > outputData_0 : register(u0);


#line 8
StructuredBuffer<float > inputData_0 : register(t0);


#line 15
[numthreads(64, 1, 1)]
void computeMain(uint index_0 : SV_DispatchThreadID)
{

#line 17
    outputData_0[index_0] = inputData_0.Load(index_0) * 2.0f + 1.0f;
    return;
}

