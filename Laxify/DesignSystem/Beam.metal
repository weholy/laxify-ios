#include <metal_stdlib>
using namespace metal;

// A drifting field of soft light beams — an approximation of the WebGL
// "beam" effect, done as a from-scratch color shader. Fed `size` and `time`
// as uniforms; ignores the incoming colour and draws over it.

static float hash(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float noise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float a = hash(i);
    float b = hash(i + float2(1.0, 0.0));
    float c = hash(i + float2(0.0, 1.0));
    float d = hash(i + float2(1.0, 1.0));
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}

[[ stitchable ]]
half4 beam(float2 pos, half4 color, float2 size, float time, half4 tint) {
    float2 uv = pos / size;

    // Rotate the space so the beams rake across at an angle.
    float ang = -0.5;
    float2 dir = float2(cos(ang), sin(ang));
    float2 nrm = float2(-dir.y, dir.x);
    float along = dot(uv - 0.5, dir);
    float across = dot(uv - 0.5, nrm);

    // Several overlapping bands, each moving at its own pace.
    float glow = 0.0;
    for (int i = 0; i < 5; i++) {
        float fi = float(i);
        float speed = 0.04 + fi * 0.015;
        float width = 0.12 + 0.05 * fi;
        float centre = fract(along * (0.6 + fi * 0.12) + time * speed + fi * 0.37) - 0.5;
        float band = exp(-pow(centre / width, 2.0));
        float flicker = 0.75 + 0.25 * noise(float2(across * 6.0 + fi * 10.0, time * 0.3 + fi));
        glow += band * flicker * (0.6 - fi * 0.08);
    }

    // Fade toward the edges so it sits inside its frame.
    float vignette = smoothstep(1.1, 0.2, length(uv - 0.5) * 1.4);
    glow *= vignette;
    glow = clamp(glow, 0.0, 1.0);

    // Premultiplied — SwiftUI's colour effects composite that way.
    float a = glow * float(tint.a);
    return half4(tint.rgb * half(a), half(a));
}
