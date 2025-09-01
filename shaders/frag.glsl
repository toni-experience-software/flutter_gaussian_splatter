#version 300 es
#ifdef GL_FRAGMENT_PRECISION_HIGH
precision highp float;
precision highp int;
#else
precision mediump float;
precision mediump int;
#endif

in highp vec4 vColor;     // upgraded from mediump
in highp vec2 vPosition;  // upgraded from mediump
out vec4 fragColor;

#if defined(GL_FRAGMENT_PRECISION_HIGH)
// Schraudolph fast exp (bitcast) — safe only at highp
const highp float EXP_A = 12102203.0;   // ≈ 2^23 / ln(2)
const highp int   EXP_B = 1064866808;   // (127 << 23) - 60801 * 8
highp float fastExp(highp float x) {
    int i = int(EXP_A * x) + EXP_B;
    return intBitsToFloat(i);
}
#else
// Fallback for GPUs without highp in fragment (e.g. some old Mali)
float fastExp(float x) { return exp2(x * 1.4426950408889634); }
#endif

void main() {
    highp float A = dot(vPosition, vPosition);

    // discard outside unit circle
    if (A > 1.0) {
        discard;
    }

    // alpha calculation with 4.0 factor
    highp float alpha = fastExp(-A * 4.0) * vColor.a;

    // alpha threshold
    if (alpha < 1.0 / 255.0) {
        discard;
    }

    // premultiplied alpha output
    fragColor = vec4(vColor.rgb * alpha, alpha);
}
