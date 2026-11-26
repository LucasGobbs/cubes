// Particle billboards via vertex pulling: no vertex buffer. Each particle is
// a quad of 6 vertices, so instance = SV_VertexID / 6. SV_InstanceID is not
// used because the draw is issued with instance count 1.
//
// SDL_GPU vertex binding order: uniforms -> read-only storage buffers.

struct Particle {
    float3 position;
    float age;
    float3 velocity;
    float lifetime;
    float4 color;
};

struct RenderParams {
    float4x4 view_projection;
    float3 cam_right;
    float size_start;
    float3 cam_up;
    float size_end;
    float4 color_end;
    float fade_in;
    float3 _pad;
    // xyz = camera position, w = streak stretch (seconds of travel drawn as length; 0 = round billboard).
    float4 stretch_cam;
    // xyz = box side lengths (wrap mode, box centred on the camera), w = 1 for wrap mode; 0 = positions as stored.
    float4 wrap_box;
    // x = fall clock seconds (wrap), y = floor world y, z = 1 to hide drops under it, w unused.
    float4 wrap_time;
};

[[vk::binding(0, 0)]]
cbuffer UniformBlock {
    RenderParams params;
}

[[vk::binding(1, 0)]]
StructuredBuffer<Particle> particles;

// Folds x into [-b/2, b/2) per axis (period b); keep in step with wrap_axis in particles/emitter.odin.
float3 wrap_axis3(float3 x, float3 b) {
    return x - b * floor(x / b + 0.5);
}

struct VertexOutput {
    float4 position : SV_POSITION;
    float4 color : COLOR;
    float2 uv : UV;
};

[shader("vertex")]
VertexOutput vertexMain(uint vid : SV_VertexID) {
    uint instance = vid / 6;
    uint corner_id = vid % 6;
    // Two triangles covering the quad [-1,1]^2.
    float2 corners[6] = {
        float2(-1.0, -1.0), float2(1.0, -1.0), float2(1.0, 1.0),
        float2(-1.0, -1.0), float2(1.0, 1.0), float2(-1.0, 1.0),
    };
    float2 corner = corners[corner_id];

    Particle p = particles[instance];
    bool wrap = params.wrap_box.w > 0.0;

    VertexOutput output;
    if (!wrap && p.age >= p.lifetime) {
        // Dead: push outside every clip plane so nothing rasterizes. w = 0 would
        // hit the perspective divide, so keep w = 1.
        output.position = float4(2.0, 2.0, 2.0, 1.0);
        output.color = float4(0.0, 0.0, 0.0, 0.0);
        output.uv = corner;
        return output;
    }

    // Wrap drops fold their fixed position (advanced by the fall clock) into the box around the camera.
    float3 center = p.position;
    float t = 0.0; // wrap drops keep colour and size; ordinary emitters age
    float edge = 1.0;
    if (wrap) {
        float3 box = params.wrap_box.xyz;
        float3 offset = wrap_axis3(p.position + p.velocity * params.wrap_time.x - params.stretch_cam.xyz, box);
        center = params.stretch_cam.xyz + offset;
        // Fade toward the box faces so the seam where a drop jumps to the opposite face is invisible.
        float3 room = (box * 0.5 - abs(offset)) / (box * 0.25);
        edge = saturate(min(room.x, min(room.y, room.z)));
    } else {
        t = p.age / p.lifetime;
    }

    float size = lerp(params.size_start, params.size_end, t);
    float3 world;
    float stretch = params.stretch_cam.w;
    float speed = length(p.velocity);
    // Floor: a drop whose streak would reach under the ground is hidden (conservative, counts the full streak).
    float reach = 0.5 * max(size, speed * stretch);
    if (wrap && params.wrap_time.z > 0.0 && center.y - reach < params.wrap_time.y) {
        edge = 0.0;
    }
    if (stretch > 0.0 && speed > 1e-4) {
        // Streak: a quad along the velocity, its width turned toward the camera. The width never drops below
        // about one pixel (distance * 0.0025 at 70 deg fov) so thin streaks fade instead of flickering.
        float3 axis = p.velocity / speed;
        float3 to_cam = params.stretch_cam.xyz - center;
        float dist = length(to_cam);
        float3 side = cross(axis, to_cam);
        side = length(side) > 1e-5 ? normalize(side) : params.cam_right;
        float width = max(size, dist * 0.002);
        world = center + axis * (corner.y * speed * stretch * 0.5) + side * (corner.x * width * 0.5);
    } else {
        world = center + (params.cam_right * corner.x + params.cam_up * corner.y) * size * 0.5;
    }

    float4 color = lerp(p.color, params.color_end, t);
    if (!wrap && params.fade_in > 0.0) {
        color.a *= saturate(t / max(params.fade_in, 1e-4));
    }
    color.a *= edge;

    output.position = mul(params.view_projection, float4(world, 1.0));
    output.color = color;
    output.uv = corner;
    return output;
}

[shader("fragment")]
float4 pixelMain(VertexOutput input) : SV_Target0 {
    // Soft round sprite: squared falloff from the quad center.
    float a = saturate(1.0 - dot(input.uv, input.uv));
    a = a * a;
    return float4(input.color.rgb, input.color.a * a);
}
