#include <metal_stdlib>
using namespace metal;

struct VertexUniforms {
    float tilt;   // radians the desktop leans back about its bottom edge
    float eyeY;   // viewer position relative to the screen centre, in half-screen-heights
    float eyeZ;
};

struct FragmentUniforms {
    float shade;    // 0…1
    float feather;  // capture pixels over which the edges fade to black, matching the blur
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// A screen-filling quad (x in half-widths, y and z in half-heights, hinge at y = -1),
// rotated about its bottom edge and projected onto the screen from the viewer's eye.
// With no tilt, w == 1 and the quad matches the real desktop pixel for pixel.
vertex VertexOut tiltVertex(uint vid [[vertex_id]], constant VertexUniforms &u [[buffer(0)]]) {
    const float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    float2 c = corners[vid];
    float r = c.y + 1.0;                                           // distance from the hinge
    float3 p = float3(c.x, r * cos(u.tilt) - 1.0, -r * sin(u.tilt)); // top edge leans away

    // Intersect the ray from the eye through p with the screen plane (z = 0), in homogeneous form.
    // The eye is always centred horizontally, so x needs no correction.
    float k = p.z / u.eyeZ;
    VertexOut out;
    out.position = float4(p.x, p.y - k * u.eyeY, 0.5 * (1.0 - k), 1.0 - k);
    out.uv = float2((c.x + 1.0) * 0.5, (1.0 - c.y) * 0.5);
    return out;
}

fragment float4 tiltFragment(VertexOut in [[stage_in]],
                             texture2d<float> frame [[texture(0)]],
                             sampler s [[sampler(0)]],
                             constant FragmentUniforms &u [[buffer(0)]]) {
    // Where the tilt squeezes the image, average four samples across the pixel's footprint so
    // text doesn't shimmer. At 1:1 (no tilt) the offsets are zero and the image stays sharp.
    float2 size = float2(frame.get_width(), frame.get_height());
    float2 dx = dfdx(in.uv);
    float2 dy = dfdy(in.uv);
    float footprint = max(length(dx * size), length(dy * size));
    float spread = 0.25 * saturate(footprint - 1.0);
    dx *= spread;
    dy *= spread;
    float3 color = 0.25 * (frame.sample(s, in.uv + dx + dy).rgb +
                           frame.sample(s, in.uv + dx - dy).rgb +
                           frame.sample(s, in.uv - dx + dy).rgb +
                           frame.sample(s, in.uv - dx - dy).rgb);

    // Darker toward the top edge, which leans furthest away.
    float shade = u.shade * mix(0.35, 0.9, 1.0 - in.uv.y);

    // Soft edges: fade to black over the blur's width, and over at least one screen pixel so the
    // slanted sides don't look jagged.
    float2 edgeDistance = min(in.uv, 1.0 - in.uv) * size;
    float fade = smoothstep(0.0, max(u.feather, footprint), min(edgeDistance.x, edgeDistance.y));
    return float4(color * (1.0 - shade) * fade, 1.0);
}

// Sums every pixel of a 64×64 cell of the frame (see FrameFingerprint). One 16×16 threadgroup per cell;
// each thread reads a 4×4 patch, then the SIMD groups and the threadgroup reduce the totals.
kernel void frameFingerprint(texture2d<float, access::read> frame [[texture(0)]],
                             device uint4 *sums [[buffer(0)]],
                             constant uint &cellsPerRow [[buffer(1)]],
                             uint2 tid [[thread_position_in_grid]],
                             uint2 group [[threadgroup_position_in_grid]],
                             uint lane [[thread_index_in_simdgroup]],
                             uint simdIndex [[simdgroup_index_in_threadgroup]]) {
    uint2 size = uint2(frame.get_width(), frame.get_height());
    uint2 origin = tid * 4;
    uint4 sum = 0;
    for (uint y = origin.y; y < min(origin.y + 4, size.y); y++) {
        for (uint x = origin.x; x < min(origin.x + 4, size.x); x++) {
            sum += uint4(frame.read(uint2(x, y)) * 255.0 + 0.5);
        }
    }
    sum = simd_sum(sum);
    threadgroup uint4 partial[8];
    if (lane == 0) partial[simdIndex] = sum;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (simdIndex == 0 && lane == 0) {
        uint4 total = 0;
        for (uint i = 0; i < 8; i++) total += partial[i];
        sums[group.y * cellsPerRow + group.x] = total;
    }
}
