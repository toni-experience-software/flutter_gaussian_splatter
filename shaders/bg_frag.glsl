#version 300 es
precision mediump float;

uniform sampler2D u_bg;        // equirect 2:1 PNG
uniform vec2      u_viewport;  // (width, height)
uniform vec2      u_focal;     // (fx, fy)
uniform mat3      u_invViewRot;// inverse view rotation (R^T)
uniform mat3      u_bgRot;     // extra yaw/pitch for sky

out vec4 frag;

// ====== CONFIG TOGGLES ======
#define SKY_WORLD_LOCKED 1   // 1: sky fixed in world (uses u_invViewRot), 0: camera-locked
#define SKY_Z_UP         0   // 1: your world uses Z-up; 0: Y-up world
#define SKY_FLIP_U       0   // <<< THIS IS THE FIX. Set it to 0.
#define SKY_FLIP_V       0   // 1: mirror vertically
#define SKY_DEBUG_MODE   0   // 0=texture, 1=dir-color, 2=UV-checker
// ============================

const float PI         = 3.14159265359;
const float INV_PI     = 0.3183098861837907;
const float INV_TWOPI  = 0.15915494309189535;

void main() {
  // Pixel -> NDC
  vec2 ndc = (gl_FragCoord.xy / u_viewport) * 2.0 - 1.0;

  // Intrinsics -> normalized slopes (matches your projection build)
  float fovX = (2.0 * u_focal.x) / u_viewport.x;
  float fovY = (2.0 * u_focal.y) / u_viewport.y;

  // Camera ray (GL convention: forward = -Z)
//  vec3 dir_cam = normalize(vec3(ndc.x / fovX, ndc.y / fovY, -1.0));
vec3 dir_cam = normalize(vec3(-ndc.x / fovX, -ndc.y / fovY, -1.0f));

  // Rotate into desired frame
  vec3 d;
#if SKY_WORLD_LOCKED
  d = normalize(u_bgRot * (u_invViewRot * dir_cam));
#else
  d = normalize(u_bgRot * dir_cam);
#endif

  // If your world is Z-up, remap to Y-up mapping frame
#if SKY_Z_UP
  // newY = oldZ, newZ = -oldY (keeps forward = -Z for mapping)
  d = vec3(d.x, d.z, -d.y);
#endif

  // --- Correct Spherical Mapping ---
  // Calculates spherical angles with a consistent right-handed coordinate system.
  // This ensures yaw (top/bottom view) and roll (side view) behave correctly.
  float yaw   = -atan(d.x, d.z);                // +yaw = clockwise (top view)
  float pitch = atan(d.y, length(d.xz));        // [-pi/2 .. +pi/2]

  // Map to [0..1] texture coordinates
  float u = yaw * INV_TWOPI + 0.5;
  float v = 0.5 - pitch * INV_PI;               // v=0 at top pole, v=1 at bottom pole

#if SKY_FLIP_U
  u = 1.0 - u;
#endif
#if SKY_FLIP_V
  v = 1.0 - v;
#endif

#if SKY_DEBUG_MODE == 1
  // Direction color: +X=red, +Y=green (sky), +Z=blue (forward)
  vec3 c = 0.5 * (d + 1.0);
  frag = vec4(c, 1.0);
#elif SKY_DEBUG_MODE == 2
  // UV checker: 8x4 tiles, thin grid lines
  float cu = step(0.5, fract(u * 8.0));
  float cv = step(0.5, fract(v * 4.0));
  float check = abs(cu - cv);
  float grid = 1.0 - smoothstep(0.49, 0.5, min(min(fract(u*8.0), fract(v*4.0)), min(1.0-fract(u*8.0), 1.0-fract(v*4.0))));
  frag = vec4(mix(vec3(check), vec3(0.0), grid*0.85), 1.0);
#else
  frag = vec4(texture(u_bg, vec2(u, v)).rgb, 1.0);
#endif
}