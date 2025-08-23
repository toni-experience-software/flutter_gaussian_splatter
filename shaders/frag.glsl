#version 300 es
precision mediump float; 
precision mediump int;    

in mediump vec4 vColor;
in mediump vec2 vPosition;

out vec4 fragColor;

void main () {
    float A = -dot(vPosition, vPosition);
    if (A < -4.0) discard; // Discard pixels outside the r=2 circle

    // finalAlpha combines the splat's base alpha with the Gaussian falloff
    float finalAlpha = vColor.a * exp(A);

    // Output pre-multiplied color: (RGB * finalAlpha, finalAlpha)
    fragColor = vec4(vColor.rgb * finalAlpha, finalAlpha);
}
