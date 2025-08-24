#version 300 es
precision mediump float;

uniform sampler2D u_bg;        // equirect 2:1 PNG, mipmapped
uniform vec2      u_viewport;  // (width, height)
uniform vec2      u_focal;     // (fx, fy)
uniform mat3      u_invViewRot;// inverse(view rotation) == transpose(view rot) for pure rotation

out vec4 frag;

void main() {
  // NDC from pixel coords
  vec2 ndc = (gl_FragCoord.xy / u_viewport) * 2.0 - 1.0;

  // Convert (fx,fy) to normalized slopes (matches your projection build)
  float fovX = (2.0 * u_focal.x) / u_viewport.x;
  float fovY = (2.0 * u_focal.y) / u_viewport.y;

  // Ray in camera space (z forward=-1 to match your usage)
  vec3 dir_cam = normalize(vec3(ndc.x / fovX, ndc.y / fovY, -1.0));
  // Remove translation: rotate into world
  vec3 dir = normalize(u_invViewRot * dir_cam);

  // Equirectangular sampling (OpenGL convention: +Y up, +Z forward)
  float u = atan(-dir.z, dir.x) / (2.0 * 3.14159265359) + 0.5;
  float v = 0.5 - asin(clamp(dir.y, -1.0, 1.0)) / 3.14159265359;

  frag = vec4(texture(u_bg, vec2(u, v)).rgb, 1.0);
}
