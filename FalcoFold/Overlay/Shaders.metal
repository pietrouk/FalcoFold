#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float tilt;       // radians
    float distance;   // viewer distance in half-screen-heights
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// Screen-filling quad in clip space, rotated about its bottom edge (y = -1).
// w == 1 when tilt == 0, so an untilted quad matches the real desktop pixel for pixel.
vertex VertexOut tiltVertex(uint vid [[vertex_id]], constant Uniforms &u [[buffer(0)]]) {
    const float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    float2 c = corners[vid];
    float r = c.y + 1.0;              // distance from the hinge
    float y = r * cos(u.tilt) - 1.0;
    float z = -r * sin(u.tilt);       // top edge leans away from the viewer
    float w = (u.distance - z) / u.distance;

    VertexOut out;
    out.position = float4(c.x, y, 0.5 * w, w);
    out.uv = float2((c.x + 1.0) * 0.5, (1.0 - c.y) * 0.5);
    return out;
}

fragment float4 tiltFragment(VertexOut in [[stage_in]],
                             texture2d<float> frame [[texture(0)]],
                             sampler s [[sampler(0)]]) {
    return float4(frame.sample(s, in.uv).rgb, 1.0);
}

