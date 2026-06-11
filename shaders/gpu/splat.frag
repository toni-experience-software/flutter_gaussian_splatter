#version 460 core

in vec4 vColor;
in vec2 vPosition;
out vec4 fragColor;

float fastExp(float x) {
    return exp2(x * 1.4426950408889634);
}

// e^-4, the falloff value at the unit-circle edge (A == 1).
#define EXP_NEG4 0.018315638888734182

// Normalized Gaussian falloff: hits exactly 0 at A == 1, removing the
// visible hard edge at the discard radius (PlayCanvas frag/gsplat.js:33).
float normExp(float A) {
    return (fastExp(-A * 4.0) - EXP_NEG4) / (1.0 - EXP_NEG4);
}

void main() {
    float A = dot(vPosition, vPosition);

    if (A > 1.0) {
        discard;
    }

    float alpha = normExp(A) * vColor.a;

    if (alpha < 1.0 / 255.0) {
        discard;
    }

    fragColor = vec4(vColor.rgb * alpha, alpha);
}
