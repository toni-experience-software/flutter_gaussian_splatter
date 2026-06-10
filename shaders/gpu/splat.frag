#version 460 core

in vec4 vColor;
in vec2 vPosition;
out vec4 fragColor;

float fastExp(float x) {
    return exp2(x * 1.4426950408889634);
}

void main() {
    float A = dot(vPosition, vPosition);

    if (A > 1.0) {
        discard;
    }

    float alpha = fastExp(-A * 4.0) * vColor.a;

    if (alpha < 2.0 / 255.0) {
        discard;
    }

    fragColor = vec4(vColor.rgb * alpha, alpha);
}
