#version 300 es
    precision highp float;   // instead of mediump
    precision highp int;     // bit-ops work on ints/uints too
    in vec4 vColor;
    in vec2 vPosition;

    out vec4 fragColor;

    void main () {
        float A = -dot(vPosition, vPosition);
        if (A < -4.0) discard; // Discard pixels outside the r=2 circle

        // finalAlpha combines the splat's base alpha with the Gaussian falloff
        float finalAlpha = vColor.a * exp(A);

        // Output pre-multiplied color: (RGB * finalAlpha, finalAlpha)
        fragColor = vec4(vColor.rgb * finalAlpha, finalAlpha);
    }