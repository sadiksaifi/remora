#include <metal_stdlib>
using namespace metal;

struct DesktopVertex {
    float4 position [[position]];
    float2 uv;
};

vertex DesktopVertex remoraDesktopVertex(uint index [[vertex_id]]) {
    const float2 positions[] = { {-1, 1}, {-1, -1}, {1, 1}, {1, -1} };
    const float2 coordinates[] = { {0, 0}, {0, 1}, {1, 0}, {1, 1} };
    return { float4(positions[index], 0, 1), coordinates[index] };
}

fragment half4 remoraDesktopFragment(DesktopVertex input [[stage_in]],
                                    texture2d<half> desktop [[texture(0)]],
                                    sampler filtering [[sampler(0)]]) {
    return half4(desktop.sample(filtering, input.uv).rgb, 1);
}
