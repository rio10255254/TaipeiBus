#include <metal_stdlib>
using namespace metal;

struct BusVertex { float4 position; float4 normal; float4 color; };
struct BusInstance { float4 position; float4 style; };
struct BusUniforms { float4x4 matrix; float4 mode; float4 viewDirection; };
struct BusFragment {
    float4 position [[position]];
    float4 color;
    float3 normal;
    float material;
    float2 uv;
    float selection;
};

// Keep the original 3D bus readable at city scale. Only its projected footprint
// grows; depth remains tied to the real road, rather than becoming a giant bus.
inline float4 readableBus(float4 clip, float4 center, float scale) {
    if (scale <= 1.001) { return clip; }
    const float2 anchor = center.xy * (clip.w / center.w);
    clip.xy = anchor + (clip.xy - anchor) * scale;
    return clip;
}

vertex BusFragment busVertex(uint vertexID [[vertex_id]], uint instanceID [[instance_id]],
                            constant BusVertex *vertices [[buffer(0)]],
                            constant BusUniforms &uniforms [[buffer(1)]],
                            constant BusInstance *instances [[buffer(2)]]) {
    const BusVertex v = vertices[vertexID];
    const BusInstance bus = instances[instanceID];
    const float c = cos(bus.style.x), s = sin(bus.style.x);
    float3 local = v.position.xyz;
    float3 normal = v.normal.xyz;
    if (v.position.w != 0) {
        // Tires roll by actual distance along received GPS geometry. Stops also stop the wheels.
        const float wc = cos(bus.style.w), ws = sin(bus.style.w);
        const float2 wheel = local.yz - float2(v.position.w, 0.51);
        local.yz = float2(wc * wheel.x + ws * wheel.y, -ws * wheel.x + wc * wheel.y) + float2(v.position.w, 0.51);
        normal.yz = float2(wc * normal.y + ws * normal.z, -ws * normal.y + wc * normal.z);
    }
    // Local east/north/up, clockwise bearing. Camera handles pitch, rotation and scale.
    float3 p = float3(c * local.x + s * local.y, -s * local.x + c * local.y, local.z) + bus.position.xyz;
    BusFragment out;
    out.position = readableBus(uniforms.matrix * float4(p, 1),
                               uniforms.matrix * float4(bus.position.xyz + float3(0,0,1.75), 1), bus.position.w);
    out.color = v.color;
    if (uniforms.mode.x == 0) { out.color.a *= max(uniforms.mode.z, bus.style.y) * uniforms.mode.w; }
    out.normal = float3(c * normal.x + s * normal.y, -s * normal.x + c * normal.y, normal.z);
    out.material = v.normal.w;
    out.selection = bus.style.y;
    out.uv = float2(0);
    if (uniforms.mode.x == 1) { out.color.a *= bus.style.y; }
    if (uniforms.mode.x == 2) {
        out.color = float4(uniforms.viewDirection.w > 0 ? float3(0.10,0.57,1.0) : float3(0.12,0.42,0.96), bus.style.y * 0.9);
    }
    else if (bus.style.z > 0) { out.color.a *= 0.48; }
    return out;
}

fragment float4 busFragment(BusFragment in [[stage_in]], constant BusUniforms &uniforms [[buffer(1)]]) {
    if (uniforms.mode.x == 2) { return in.color; }
    const float3 n = normalize(in.normal);
    const float3 light = normalize(float3(-0.45, -0.35, 0.82));
    const float diffuse = 0.70 + 0.28 * max(0.0, dot(n, light));
    const float3 view = normalize(uniforms.viewDirection.xyz);
    const float rim = pow(1.0 - abs(dot(n, view)), 3.0);
    float3 color = in.color.rgb * diffuse;
    if (in.material < 1.5) {
        const float specular = pow(max(0.0, dot(n, normalize(light + view))), in.material > 0.5 ? 48.0 : 28.0);
        color += specular * (in.material > 0.5 ? 0.12 : 0.055);
        color += rim * float3(0.035, 0.042, 0.050);
    }
    if (in.material > 2.5) { color = in.color.rgb; }
    // Far-away buses retain their body geometry, but lose harsh window/roof
    // contrast smoothly so many vehicles read as a quiet neutral-gray flow.
    if (uniforms.mode.x == 0 && uniforms.mode.y > 0) {
        color = mix(color, float3(0.73) * diffuse, uniforms.mode.y * 0.55);
    }
    if (uniforms.mode.x == 0 && in.material < 0.5) {
        color = mix(color, uniforms.viewDirection.w > 0 ? float3(0.24,0.64,0.96) : float3(0.31,0.59,0.85), in.selection * 0.55);
    }
    return float4(color, in.color.a);
}

vertex BusFragment busShadowVertex(uint vertexID [[vertex_id]], uint instanceID [[instance_id]],
                                  constant BusVertex *vertices [[buffer(0)]],
                                  constant BusUniforms &uniforms [[buffer(1)]],
                                  constant BusInstance *instances [[buffer(2)]]) {
    const BusVertex v = vertices[vertexID];
    const BusInstance bus = instances[instanceID];
    const float c = cos(bus.style.x), s = sin(bus.style.x);
    float3 p = float3(c * v.position.x + s * v.position.y, -s * v.position.x + c * v.position.y, 0.035) + bus.position.xyz;
    BusFragment out;
    out.position = readableBus(uniforms.matrix * float4(p, 1),
                               uniforms.matrix * float4(bus.position.xyz + float3(0,0,1.75), 1), bus.position.w);
    out.uv = v.normal.xy;
    out.color = float4(uniforms.viewDirection.w > 0 ? float3(0.025) : float3(0.10,0.12,0.15), bus.style.z > 0 ? 0.10 : 0.22);
    out.color.a *= max(uniforms.mode.z, bus.style.y);
    out.normal = float3(0, 0, 1);
    out.material = 0;
    out.selection = bus.style.y;
    return out;
}

fragment float4 busShadowFragment(BusFragment in [[stage_in]]) {
    const float2 q = abs(in.uv) - float2(0.67, 0.83);
    const float distance = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
    const float softness = 1.0 - smoothstep(0.0, 0.25, distance);
    const float contact = 1.0 - smoothstep(-0.18, 0.12, distance);
    const float3 color = mix(in.color.rgb, float3(0.12, 0.36, 0.77), in.selection * 0.12);
    return float4(color, in.color.a * softness * (0.55 + 0.45 * contact));
}
