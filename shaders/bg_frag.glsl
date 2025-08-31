#version 300 es
precision mediump float;

uniform sampler2D u_bg;
uniform vec2      u_viewport;
uniform vec2      u_focal;
uniform mat3      u_invViewRot;
uniform mat3      u_bgRot;

out vec4 frag;

#define SKY_WORLD_LOCKED 1
#define SKY_Z_UP         0
#define SKY_FLIP_U       0
#define SKY_FLIP_V       0
#define SKY_DEBUG_MODE   0

#define SKY_MOVE_ORIGIN      1
#define SPHERE_RADIUS        1.0
#define ORIGIN_Y_OFFSET      0.0

const float PI         = 3.14159265359;
const float INV_PI     = 0.3183098861837907;
const float INV_TWOPI  = 0.15915494309189535;

void main() {
  vec2 ndc = (gl_FragCoord.xy / u_viewport) * 2.0 - 1.0;

  float fovX = (2.0 * u_focal.x) / u_viewport.x;
  float fovY = (2.0 * u_focal.y) / u_viewport.y;

  float skyZoomFactor = 0.5;
  fovX *= skyZoomFactor;
  fovY *= skyZoomFactor;

  vec3 dir_cam = normalize(vec3(-ndc.x / fovX, -ndc.y / fovY, -1.0f));

  vec3 d;
#if SKY_WORLD_LOCKED
  d = normalize(u_bgRot * (u_invViewRot * dir_cam));
#else
  d = normalize(u_bgRot * dir_cam);
#endif

#if SKY_Z_UP
  d = vec3(d.x, d.z, -d.y);
#endif

#if SKY_MOVE_ORIGIN
  if (ORIGIN_Y_OFFSET != 0.0) {
    vec3 C = vec3(0.0, -ORIGIN_Y_OFFSET, 0.0);
    float R = max(float(SPHERE_RADIUS), 1e-3);

    vec3 oc = -C;
    float b = dot(oc, d);
    float c = dot(oc, oc) - R*R;
    float disc = b*b - c;

    if (disc > 0.0) {
      float t = -b + sqrt(disc);
      vec3 P = d * t;
      vec3 n = normalize(P - C);
      d = n;
    }
  }
#endif

  float yaw   = -atan(d.x, d.z);
  float pitch = atan(d.y, length(d.xz));

  float u = yaw * INV_TWOPI + 0.5;
  float v = 0.5 - pitch * INV_PI;

#if SKY_FLIP_U
  u = 1.0 - u;
#endif
#if SKY_FLIP_V
  v = 1.0 - v;
#endif

#if SKY_DEBUG_MODE == 1
  vec3 c = 0.5 * (d + 1.0);
  frag = vec4(c, 1.0);
#elif SKY_DEBUG_MODE == 2
  float cu = step(0.5, fract(u * 8.0));
  float cv = step(0.5, fract(v * 4.0));
  float check = abs(cu - cv);
  float grid = 1.0 - smoothstep(0.49, 0.5, min(min(fract(u*8.0), fract(v*4.0)), min(1.0-fract(u*8.0), 1.0-fract(v*4.0))));
  frag = vec4(mix(vec3(check), vec3(0.0), grid*0.85), 1.0);
#else
  frag = vec4(texture(u_bg, vec2(u, v)).rgb, 1.0);
#endif
}
