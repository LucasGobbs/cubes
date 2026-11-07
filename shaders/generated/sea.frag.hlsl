#pragma pack_matrix(column_major)
#ifdef SLANG_HLSL_ENABLE_NVAPI
#include "nvHLSLExtns.h"
#endif

#ifndef __DXC_VERSION_MAJOR
// warning X3557: loop doesn't seem to do anything, forcing loop to unroll
#pragma warning(disable : 3557)
#endif


#line 34 "shaders/sea.slang"
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



float3 swell_0(float2 p_0, float freq_0, float speed_0, float time_0)
{

#line 63
    float2 q_0 = p_0 * freq_0 + float2(time_0 * speed_0, 0.0f);
    float s_0 = simplex2_0(q_0);
    return float3(s_0, simplex2_0(q_0 + float2(freq_0, 0.0f)) - s_0, simplex2_0(q_0 + float2(0.0f, freq_0)) - s_0);
}


#line 74
float wave_height_0(float2 p_1, float time_1, float dist_0, int wave_count_0, bool fine_0, out float2 grad_0)
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
        float phase_0 = dot(dir_0, p_1) * k_0 - sqrt(9.81000041961669922f * k_0) * time_1;
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
    float3 broad_0 = swell_0(p_1, 0.00800000037997961f, 0.00999999977648258f, time_1);
    float _S4 = nf_0 * 3.0f;

#line 94
    float h_3 = h_1 + _S4 * broad_0.x;
    grad_0 = grad_0 + _S4 * broad_0.yz;
    if(fine_0)
    {
        float3 fine_swell_0 = swell_0(p_1, 0.02999999932944775f, -0.01999999955296516f, time_1);
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


#line 155
float2 flow_0(float2 p_2, float time_2)
{

#line 156
    return float2(sin(p_2.y * 0.60000002384185791f + time_2 * 0.69999998807907104f), cos(p_2.x * 0.5f - time_2 * 0.5f)) * 0.11999999731779099f;
}


#line 130
float2 hash22_0(float2 p_3)
{
    return frac(sin(float2(dot(p_3, float2(127.09999847412109375f, 311.70001220703125f)), dot(p_3, float2(269.5f, 183.3000030517578125f)))) * 43758.546875f);
}



float ring_foam_0(float2 p_4, float time_3, float aa_0)
{

#line 138
    float2 _S6 = floor(p_4);

#line 138
    float coverage_0 = 0.0f;

#line 138
    int j_0 = int(-1);

    for(;;)
    {

#line 140
        if(j_0 <= int(1))
        {
        }
        else
        {

#line 140
            break;
        }

#line 140
        int i_3 = int(-1);
        for(;;)
        {

#line 141
            if(i_3 <= int(1))
            {
            }
            else
            {

#line 141
                break;
            }

#line 142
            float2 c_0 = _S6 + float2(float(i_3), float(j_0));
            float2 h_5 = hash22_0(c_0);

            float _S7 = h_5.x;


            float _S8 = max(coverage_0, (1.0f - smoothstep(0.05000000074505806f - aa_0, 0.05000000074505806f + aa_0, abs(length(p_4 - (c_0 + 0.20000000298023224f + 0.60000002384185791f * hash22_0(c_0 + 17.0f))) - (0.14000000059604645f + 0.10000000149011612f * h_5.y + 0.02999999932944775f * sin(time_3 * 1.5f + 6.28310012817382812f * _S7))))) * step(_S7, 0.18000000715255737f));

#line 141
            int _S9 = i_3 + int(1);

#line 141
            coverage_0 = _S8;

#line 141
            i_3 = _S9;

#line 141
        }

#line 140
        j_0 = j_0 + int(1);

#line 140
    }

#line 151
    return coverage_0;
}


#line 125
float to_linear_channel_0(float c_1)
{

#line 125
    float _S10;
    if(c_1 <= 0.04044999927282333f)
    {

#line 126
        _S10 = c_1 / 12.92000007629394531f;

#line 126
    }
    else
    {

#line 126
        _S10 = pow((c_1 + 0.05499999970197678f) / 1.0549999475479126f, 2.40000009536743164f);

#line 126
    }

#line 126
    return _S10;
}


#line 23
struct VertexOutput_0
{
    float4 position_0 : SV_POSITION;
    float3 world_0 : WORLD;
    float3 to_camera_0 : TO_CAMERA;
    float time_4 : TIME;
    float4 fog_0 : FOG;
};


#line 160
float4 pixelMain(VertexOutput_0 input_0) : SV_TARGET
{

#line 161
    float dist_1 = length(input_0.to_camera_0);
    float3 v_1 = input_0.to_camera_0 / dist_1;

    float2 grad_1;
    float _S11 = wave_height_0(input_0.world_0.xz, input_0.time_4, dist_1, int(10), true, grad_1);
    float3 n_0 = normalize(float3(- grad_1.x, 1.0f, - grad_1.y));


    float3 body_0 = float3(0.10999999940395355f, 0.47999998927116394f, 0.81999999284744263f);
    float3 light_0 = float3(0.27000001072883606f, 0.63999998569488525f, 0.89999997615814209f);
    float3 dark_0 = float3(0.07999999821186066f, 0.37999999523162842f, 0.70999997854232788f);
    float3 foam_0 = float3(0.94999998807907104f, 0.98000001907348633f, 1.0f);
    float3 sky_0 = float3(0.67100000381469727f, 0.75700002908706665f, 0.94900000095367432f);

#line 173
    float3 color_0;

#line 178
    if((dot(n_0, float3(0.32440000772476196f, 0.81110000610351562f, 0.48669999837875366f))) > 0.82999998331069946f)
    {

#line 178
        color_0 = light_0;

#line 178
    }
    else
    {

#line 178
        color_0 = body_0;

#line 178
    }

#line 190
    float foam_fade_0 = 1.0f - smoothstep(80.0f, 220.0f, dist_1);


    float2 p_5 = input_0.world_0.xz * 0.20000000298023224f;
    float _S12 = max((fwidth((p_5.x))), (fwidth((p_5.y))));
    float2 q_1 = p_5 + flow_0(p_5, input_0.time_4);

#line 203
    float3 color_1 = lerp(lerp(lerp(lerp(lerp(lerp(color_0, color_0 * lerp(float3(0.05999999865889549f, 0.30000001192092896f, 0.72000002861022949f), float3(0.11999999731779099f, 0.62000000476837158f, 0.77999997138977051f), (float3)smoothstep(0.25f, 0.75f, 0.5f + 0.5f * simplex2_0(input_0.world_0.xz * 0.01200000010430813f + input_0.time_4 * 0.00999999977648258f))) / body_0, (float3)0.69999998807907104f), sky_0, (float3)(pow(1.0f - saturate(dot(n_0, v_1)), 3.0f) * 0.69999998807907104f)), dark_0, (float3)(0.30000001192092896f * foam_fade_0 * ring_foam_0(q_1 + 0.5f, input_0.time_4 * 0.80000001192092896f, _S12))), foam_0, (float3)(foam_fade_0 * ring_foam_0(q_1, input_0.time_4, _S12))), foam_0, (float3)(foam_fade_0 * smoothstep(0.44999998807907104f, 0.55000001192092896f, length(grad_1)))), sky_0, (float3)smoothstep(60.0f, 900.0f, dist_1));

#line 210
    return float4(lerp(float3(to_linear_channel_0(color_1.x), to_linear_channel_0(color_1.y), to_linear_channel_0(color_1.z)), input_0.fog_0.xyz, (float3)input_0.fog_0.w), 1.0f);
}

