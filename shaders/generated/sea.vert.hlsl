#pragma pack_matrix(column_major)
#ifdef SLANG_HLSL_ENABLE_NVAPI
#include "nvHLSLExtns.h"
#endif

#ifndef __DXC_VERSION_MAJOR
// warning X3557: loop doesn't seem to do anything, forcing loop to unroll
#pragma warning(disable : 3557)
#endif


#line 6 "shaders/sea.slang"
struct Uniforms_0
{
    float4x4 mvp_0;
    float4x4 model_0;
    float4 camera_position_0;
    float4 time_0;
    float4 fog_0;
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

#line 34
float2 mod289_2_0(float2 x_0)
{

#line 34
    return x_0 - floor(x_0 * 0.00346020772121847f) * 289.0f;
}


#line 33
float3 mod289_3_0(float3 x_1)
{

#line 33
    return x_1 - floor(x_1 * 0.00346020772121847f) * 289.0f;
}


#line 35
float3 permute3_0(float3 x_2)
{

#line 35
    return mod289_3_0((x_2 * 34.0f + 1.0f) * x_2);
}


#line 37
float simplex2_0(float2 v_0)
{
    float2 i_0 = floor(v_0 + dot(v_0, float2(0.3660254180431366f, 0.3660254180431366f)));
    float2 x0_0 = v_0 - i_0 + dot(i_0, float2(0.21132487058639526f, 0.21132487058639526f));
    float _S1 = x0_0.x;

#line 41
    float _S2 = x0_0.y;

#line 41
    float2 i1_0;

#line 41
    if(_S1 > _S2)
    {

#line 41
        i1_0 = float2(1.0f, 0.0f);

#line 41
    }
    else
    {

#line 41
        i1_0 = float2(0.0f, 1.0f);

#line 41
    }
    float4 _S3 = x0_0.xyxy + float4(0.21132487058639526f, 0.21132487058639526f, -0.57735025882720947f, -0.57735025882720947f);

#line 42
    float4 x12_0 = _S3;
    x12_0.xy = _S3.xy - i1_0;
    float2 i_1 = mod289_2_0(i_0);

    float3 m_0 = max(0.5f - float3(dot(x0_0, x0_0), dot(x12_0.xy, x12_0.xy), dot(x12_0.zw, x12_0.zw)), (float3)0.0f);
    float3 m_1 = m_0 * m_0;

    float3 x_3 = 2.0f * frac(permute3_0(permute3_0(i_1.y + float3(0.0f, i1_0.y, 1.0f)) + i_1.x + float3(0.0f, i1_0.x, 1.0f)) * float3(0.02439024299383163f, 0.02439024299383163f, 0.02439024299383163f)) - 1.0f;
    float3 h_0 = abs(x_3) - 0.5f;

    float3 a0_0 = x_3 - floor(x_3 + 0.5f);
    float3 m_2 = m_1 * m_1 * (1.79284286499023438f - 0.85373473167419434f * (a0_0 * a0_0 + h_0 * h_0));
    float3 g_0;
    g_0[int(0)] = a0_0.x * _S1 + h_0.x * _S2;
    g_0.yz = a0_0.yz * x12_0.xz + h_0.yz * x12_0.yw;
    return 130.0f * dot(m_2, g_0);
}



float3 swell_0(float2 p_0, float freq_0, float speed_0, float time_1)
{

#line 63
    float2 q_0 = p_0 * freq_0 + float2(time_1 * speed_0, 0.0f);
    float s_0 = simplex2_0(q_0);
    return float3(s_0, simplex2_0(q_0 + float2(freq_0, 0.0f)) - s_0, simplex2_0(q_0 + float2(0.0f, freq_0)) - s_0);
}


#line 74
float wave_height_0(float2 p_1, float time_2, float dist_0, int wave_count_0, bool fine_0, out float2 grad_0)
{
    grad_0 = float2(0.0f, 0.0f);

#line 76
    int i_2 = int(0);

#line 76
    float wavelength_0 = 70.0f;

#line 76
    float angle_0 = 0.30000001192092896f;

#line 76
    float h_1 = 0.0f;


    for(;;)
    {

#line 79
        if(i_2 < wave_count_0)
        {
        }
        else
        {

#line 79
            break;
        }

#line 80
        float k_0 = 6.28318548202514648f / wavelength_0;

        float amplitude_0 = 0.05999999865889549f / k_0;
        float2 dir_0 = float2(cos(angle_0), sin(angle_0));
        float fade_0 = 1.0f - smoothstep(wavelength_0 * 80.0f, wavelength_0 * 160.0f, dist_0);
        float phase_0 = dot(dir_0, p_1) * k_0 - sqrt(9.81000041961669922f * k_0) * time_2;
        float h_2 = h_1 + amplitude_0 * sin(phase_0) * fade_0;
        grad_0 = grad_0 + amplitude_0 * k_0 * cos(phase_0) * dir_0 * fade_0;
        float wavelength_1 = wavelength_0 * 0.68000000715255737f;
        float angle_1 = angle_0 + 2.39996004104614258f;

#line 79
        i_2 = i_2 + int(1);

#line 79
        wavelength_0 = wavelength_1;

#line 79
        angle_0 = angle_1;

#line 79
        h_1 = h_2;

#line 79
    }

#line 92
    float nf_0 = 1.0f - smoothstep(300.0f, 1500.0f, dist_0);
    float3 broad_0 = swell_0(p_1, 0.00800000037997961f, 0.00999999977648258f, time_2);
    float _S4 = nf_0 * 3.0f;

#line 94
    float h_3 = h_1 + _S4 * broad_0.x;
    grad_0 = grad_0 + _S4 * broad_0.yz;
    if(fine_0)
    {
        float3 fine_swell_0 = swell_0(p_1, 0.02999999932944775f, -0.01999999955296516f, time_2);
        float _S5 = nf_0 * 1.5f;

#line 99
        float h_4 = h_3 + _S5 * fine_swell_0.x;
        grad_0 = grad_0 + _S5 * fine_swell_0.yz;

#line 100
        h_1 = h_4;

#line 96
    }
    else
    {

#line 96
        h_1 = h_3;

#line 96
    }

#line 102
    return h_1;
}


#line 23
struct VertexOutput_0
{
    float4 position_0 : SV_POSITION;
    float3 world_0 : WORLD;
    float3 to_camera_0 : TO_CAMERA;
    float time_3 : TIME;
    float4 fog_1 : FOG;
};


#line 19
struct VertexInput_0
{
    float3 position_1 : POSITION;
};


#line 108
VertexOutput_0 vertexMain(VertexInput_0 input_0)
{
    float4 flat_world_0 = mul(UniformBlock_0.data_0.model_0, float4(input_0.position_1, 1.0f));

    float dist_1 = length(UniformBlock_0.data_0.camera_position_0.xyz - flat_world_0.xyz);
    float3 local_0 = input_0.position_1;

#line 111
    float2 grad_1;


    local_0[int(1)] = local_0[int(1)] + wave_height_0(flat_world_0.xz, UniformBlock_0.data_0.time_0.x, dist_1, int(3), false, grad_1);
    float4 world_1 = mul(UniformBlock_0.data_0.model_0, float4(local_0, 1.0f));

#line 109
    VertexOutput_0 output_0;

#line 116
    output_0.position_0 = mul(UniformBlock_0.data_0.mvp_0, float4(local_0, 1.0f));
    float3 _S6 = world_1.xyz;

#line 117
    output_0.world_0 = _S6;
    output_0.to_camera_0 = UniformBlock_0.data_0.camera_position_0.xyz - _S6;
    output_0.time_3 = UniformBlock_0.data_0.time_0.x;

#line 119
    float t_0;
    if((UniformBlock_0.data_0.fog_0.w) > 0.0f)
    {

#line 120
        t_0 = saturate((length(output_0.to_camera_0) - 0.60000002384185791f * UniformBlock_0.data_0.fog_0.w) / (0.40000000596046448f * UniformBlock_0.data_0.fog_0.w));

#line 120
    }
    else
    {

#line 120
        t_0 = 0.0f;

#line 120
    }
    output_0.fog_1 = float4(UniformBlock_0.data_0.fog_0.xyz, t_0);
    return output_0;
}

