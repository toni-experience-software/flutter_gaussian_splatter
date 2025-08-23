#version 300 es
precision mediump float;
precision highp   int;      // <-- important for fastExp constants & intBitsToFloat

in mediump vec4 vColor;
in mediump vec2 vPosition;
out vec4 fragColor;

// Schraudolph fast exp (bitcast)
const float EXP_A = 12102203.0;     // ≈ 2^23 / ln(2)
const int   EXP_B = 1064866808;     // (127 << 23) - 60801 * 8
float fastExp(float x) {
    int i = int(EXP_A * x) + EXP_B;
    return intBitsToFloat(i);
}

/* If a driver still dislikes intBitsToFloat, replace fastExp with:
float fastExp(float x) { return exp2(x * 1.4426950408889634); } */

void main () {
    float r2 = dot(vPosition, vPosition);
    if (r2 > 4.0) {
        discard; // outside r=2 circle
    }

    float finalAlpha = vColor.a * fastExp(-r2);

    if (finalAlpha < 1.0 / 255.0) {
        discard; // negligible blend
    }

    // premultiplied output
    fragColor = vec4(vColor.rgb * finalAlpha, finalAlpha);
}
