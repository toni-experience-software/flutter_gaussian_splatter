#version 300 es
precision mediump float;
precision highp int;     

in mediump vec4 vColor;
in mediump vec2 vPosition;
out vec4 fragColor;


// Schraudolph fast exp (bitcast)
const float EXP_A = 12102203.0f;     // ≈ 2^23 / ln(2)
const int EXP_B = 1064866808;     // (127 << 23) - 60801 * 8
float fastExp(float x) {
    int i = int(EXP_A * x) + EXP_B;
    return intBitsToFloat(i);
}

/* If a driver still dislikes intBitsToFloat, replace fastExp with:
float fastExp(float x) { return exp2(x * 1.4426950408889634); } */

void main() {
    //coordinate system: [-1,1] range, unit circle
    mediump float A = dot(vPosition, vPosition);
    
    // discard outside unit circle
    if(A > 1.0f) {
        discard; // outside unit circle
    }

    // alpha calculation with 4.0 factor
    mediump float alpha = fastExp(-A * 4.0f) * vColor.a;

    // alpha threshold
    if(alpha < 1.0f / 255.0f) {
        discard; // negligible blend contribution
    }

    // premultiplied alpha output
    fragColor = vec4(vColor.rgb * alpha, alpha);
}
