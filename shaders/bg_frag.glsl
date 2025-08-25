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

// Enable the "move origin" illusion (off-center inside a finite sphere)
#define SKY_MOVE_ORIGIN      1

// ---- Tweak these two for testing (no uniforms needed) ----
#define SPHERE_RADIUS        1.0    // arbitrary units; just keep it > 0
#define ORIGIN_Y_OFFSET      0.2   // +Y raises the eye: ~20% of radius feels subtle
// ----------------------------------------------------------

const float PI         = 3.14159265359;
const float INV_PI     = 0.3183098861837907;
const float INV_TWOPI  = 0.15915494309189535;

void main() {
  // Pixel -> NDC
  vec2 ndc = (gl_FragCoord.xy / u_viewport) * 2.0 - 1.0;

  // Intrinsics -> normalized slopes (wider FOV for distant sky feel)
  float fovX = (2.0 * u_focal.x) / u_viewport.x;
  float fovY = (2.0 * u_focal.y) / u_viewport.y;

  // Scale down the FOV factors to show more of the sky (infinite distance effect)
  float skyZoomFactor = 0.5; // Lower values = more sky visible, more distant feeling
  fovX *= skyZoomFactor;
  fovY *= skyZoomFactor;

  // Camera ray (GL convention: forward = -Z)
  // vec3 dir_cam = normalize(vec3(ndc.x / fovX, ndc.y / fovY, -1.0));
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

  // ===== Off-center sampling inside a finite sphere (no uniforms) =====
#if SKY_MOVE_ORIGIN
  // Only do work if there's a non-zero offset
  if (ORIGIN_Y_OFFSET != 0.0) {
    // Mapping frame: camera at origin O=0, view dir d (|d|=1)
    vec3 C = vec3(0.0, -ORIGIN_Y_OFFSET, 0.0); // sphere center below the eye
    float R = max(float(SPHERE_RADIUS), 1e-3);

    // Ray-sphere intersection: |t*d - C|^2 = R^2
    vec3 oc = -C;                         // O - C
    float b = dot(oc, d);                 // half of the usual 'B'
    float c = dot(oc, oc) - R*R;
    float disc = b*b - c;                 // since a=1 and we folded the 2

    if (disc > 0.0) {
      // We're inside; take the far exit point
      float t = -b + sqrt(disc);
      vec3 P = d * t;
      vec3 n = normalize(P - C);          // normal at hit point
      d = n;                              // use normal for spherical mapping
    }
    // else: degenerate, keep original 'd'
  }
#endif
  // ====================================================================

  // --- Correct Spherical Mapping ---
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
