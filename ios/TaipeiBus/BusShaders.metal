#include <metal_stdlib>
using namespace metal;

struct BusVertex { float4 position; float4 color; };
struct BusInstance { float4 position; float4 style; };
struct BusUniforms { float4x4 matrix; float4 mode; };
struct BusFragment { float4 position [[position]]; float4 color; };

vertex BusFragment busVertex(uint vertexID [[vertex_id]], uint instanceID [[instance_id]],
                            constant BusVertex *vertices [[buffer(0)]],
                            constant BusUniforms &uniforms [[buffer(1)]],
                            constant BusInstance *instances [[buffer(2)]]) {
    const BusVertex v = vertices[vertexID];
    const BusInstance bus = instances[instanceID];
    const float c = cos(bus.style.x), s = sin(bus.style.x);
    // Local east/north/up, clockwise bearing. Camera handles pitch, rotation and scale.
    float3 p = float3(c * v.position.x + s * v.position.y,
                     -s * v.position.x + c * v.position.y, v.position.z) + bus.position.xyz;
    BusFragment out;
    out.position = uniforms.matrix * float4(p, 1);
    out.color = v.color;
    if (uniforms.mode.x == 1) { out.color.rgb *= 0.70; }
    if (uniforms.mode.x == 2) { out.color = float4(0.16, 0.42, 0.96, 1); }
    else if (bus.style.z > 0) { out.color.a = 0.5; }
    return out;
}

fragment float4 busFragment(BusFragment in [[stage_in]]) { return in.color; }
