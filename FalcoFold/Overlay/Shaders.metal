#include <metal_stdlib>
using namespace metal;

struct VertexUniforms {
    float tilt;   // radians the desktop leans back about its bottom edge
    float eyeY;   // viewer position relative to the screen centre, in half-screen-heights
    float eyeZ;
};

struct FragmentUniforms {
    float shade;  // 0…1
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
    return float4(color * (1.0 - shade), 1.0);
}
