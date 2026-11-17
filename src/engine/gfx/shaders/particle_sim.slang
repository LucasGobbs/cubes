// Particle simulation: one thread per ring slot. Slots inside the
// [spawn_start, spawn_start + spawn_count) window (mod capacity) are reset
// to fresh particles; other live slots integrate. Dead slots (age >= lifetime)
// are left untouched so an all-zero buffer stays dead.
//
// SDL_GPU compute binding order: uniforms -> read-only storage buffers ->
// read-write storage buffers.

struct Particle {
    float3 position;
    float age;
    float3 velocity;
    float lifetime;
    float4 color;
};

struct SimParams {
    float3 gravity;
    float dt;
    float drag;
    uint capacity;
    uint spawn_start;
    uint spawn_count;
    float3 origin;
    uint seed;
    float3 direction;
    float spread;
    float life_min;
    float life_max;
    float speed_min;
    float speed_max;
    float4 color;
    float radius;
    float3 _pad;
};

[[vk::binding(0, 0)]]
cbuffer UniformBlock {
    SimParams params;
}

[[vk::binding(1, 0)]]
RWStructuredBuffer<Particle> particles;

// PCG hash: cheap, well-distributed integer mixing for GPU randomness.
uint pcg(uint v) {
    uint state = v * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

// Uniform [0,1) from (slot, seed, salt). Shifting to 24 bits keeps the
// result strictly below 1.0, unlike converting the full 32-bit hash.
float rand01(uint slot, uint seed, uint salt) {
    uint h = pcg(pcg(slot ^ pcg(seed)) + salt);
    return float(h >> 8) * (1.0 / 16777216.0);
}

void spawn(uint i, inout Particle p) {
    uint s = params.seed;

    // Uniform point in a sphere: cube-root of a uniform radius keeps density even.
    float z = 2.0 * rand01(i, s, 1) - 1.0;
    float phi = 6.2831853 * rand01(i, s, 2);
    float rxy = sqrt(max(0.0, 1.0 - z * z));
    float3 offset = float3(rxy * cos(phi), rxy * sin(phi), z)
        * (params.radius * pow(rand01(i, s, 3), 1.0 / 3.0));

    // Uniform-in-cos around the axis samples a cone uniformly by solid angle.
    // spread = 0 gives cos_t = 1 exactly, so the axis is returned unchanged.
    float3 d = params.direction;
    float cos_t = lerp(cos(params.spread), 1.0, rand01(i, s, 4));
    float sin_t = sqrt(max(0.0, 1.0 - cos_t * cos_t));
    float az = 6.2831853 * rand01(i, s, 5);
    float3 helper = abs(d.y) < 0.999 ? float3(0.0, 1.0, 0.0) : float3(1.0, 0.0, 0.0);
    float3 bx = normalize(cross(helper, d));
    float3 by = cross(d, bx);
    float3 dir = d * cos_t + (bx * cos(az) + by * sin(az)) * sin_t;

    float speed = lerp(params.speed_min, params.speed_max, rand01(i, s, 6));
    float life = lerp(params.life_min, params.life_max, rand01(i, s, 7));

    p.position = params.origin + offset;
    p.velocity = dir * speed;
    p.age = 0.0;
    p.lifetime = life;
    p.color = params.color;
}

[shader("compute")]
[numthreads(64, 1, 1)]
void computeMain(uint i : SV_DispatchThreadID)
{
    if (i >= params.capacity) { return; }

    Particle p = particles[i];
    uint ring_offset = (i + params.capacity - params.spawn_start) % params.capacity;
    if (ring_offset < params.spawn_count) {
        spawn(i, p);
        particles[i] = p;
        return;
    }

    if (p.age >= p.lifetime) { return; }

    p.velocity += params.gravity * params.dt;
    // Implicit-style drag keeps velocity stable for large dt.
    p.velocity *= 1.0 / (1.0 + params.drag * params.dt);
    p.position += p.velocity * params.dt;
    p.age += params.dt;
    particles[i] = p;
}
