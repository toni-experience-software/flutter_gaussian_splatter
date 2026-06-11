#version 460 core

// Evaluates spherical harmonics once per splat into an RGBA8 texture, using a
// single global view direction (camera forward in world space). The main
// vertex shader then does one color fetch instead of 12 SH fetches + eval.
// This is PlayCanvas's resolve-SH approximation (gsplat-resolve-sh.js): the
// global direction trades per-splat view-dependent shading for a large
// vertex-stage reduction, gated behind a quality toggle on the CPU side.

uniform ShResolveInfo {
  vec3 view_dir;
  float splat_count;
  float sh_height;
  float sidecar_height;
} resolve_info;

uniform sampler2D u_sh_texture;
uniform sampler2D u_color_texture;

out vec4 fragColor;

vec4 fetchTexel(sampler2D source, vec2 texel, vec2 size) {
    return texture(source, (texel + vec2(0.5)) / size);
}

vec4 fetchSidecar(sampler2D source, float idx) {
    return fetchTexel(
        source,
        vec2(mod(idx, 512.0), floor(idx / 512.0)),
        vec2(512.0, resolve_info.sidecar_height));
}

vec4 fetchSH(float idx, float coefficientGroup) {
    float shIndex = idx * 12.0 + coefficientGroup;
    return fetchTexel(
        u_sh_texture,
        vec2(mod(shIndex, 512.0), floor(shIndex / 512.0)),
        vec2(512.0, resolve_info.sh_height));
}

vec4 unpackSH(vec4 packed) {
    return packed * 8.0 - 4.0;
}

void readSHData(float idx, out vec3 sh[15]) {
    vec4 r0 = unpackSH(fetchSH(idx, 0.0));
    vec4 r1 = unpackSH(fetchSH(idx, 1.0));
    vec4 r2 = unpackSH(fetchSH(idx, 2.0));
    vec4 r3 = unpackSH(fetchSH(idx, 3.0));
    vec4 g0 = unpackSH(fetchSH(idx, 4.0));
    vec4 g1 = unpackSH(fetchSH(idx, 5.0));
    vec4 g2 = unpackSH(fetchSH(idx, 6.0));
    vec4 g3 = unpackSH(fetchSH(idx, 7.0));
    vec4 b0 = unpackSH(fetchSH(idx, 8.0));
    vec4 b1 = unpackSH(fetchSH(idx, 9.0));
    vec4 b2 = unpackSH(fetchSH(idx, 10.0));
    vec4 b3 = unpackSH(fetchSH(idx, 11.0));

    sh[0] = vec3(r0.x, g0.x, b0.x);
    sh[1] = vec3(r0.y, g0.y, b0.y);
    sh[2] = vec3(r0.z, g0.z, b0.z);
    sh[3] = vec3(r0.w, g0.w, b0.w);
    sh[4] = vec3(r1.x, g1.x, b1.x);
    sh[5] = vec3(r1.y, g1.y, b1.y);
    sh[6] = vec3(r1.z, g1.z, b1.z);
    sh[7] = vec3(r1.w, g1.w, b1.w);
    sh[8] = vec3(r2.x, g2.x, b2.x);
    sh[9] = vec3(r2.y, g2.y, b2.y);
    sh[10] = vec3(r2.z, g2.z, b2.z);
    sh[11] = vec3(r2.w, g2.w, b2.w);
    sh[12] = vec3(r3.x, g3.x, b3.x);
    sh[13] = vec3(r3.y, g3.y, b3.y);
    sh[14] = vec3(r3.z, g3.z, b3.z);
}

#define SH_C1 0.4886025119029199
#define SH_C2_0 1.0925484305920792
#define SH_C2_1 -1.0925484305920792
#define SH_C2_2 0.31539156525252005
#define SH_C2_3 -1.0925484305920792
#define SH_C2_4 0.5462742152960396
#define SH_C3_0 -0.5900435899266435
#define SH_C3_1 2.890611442640554
#define SH_C3_2 -0.4570457994644658
#define SH_C3_3 0.3731763325901154
#define SH_C3_4 -0.4570457994644658
#define SH_C3_5 1.445305721320277
#define SH_C3_6 -0.5900435899266435

vec3 evalSH(in vec3 dir, in vec3 sh[15]) {
    float x = dir.x, y = dir.y, z = dir.z;
    vec3 result = SH_C1 * (-sh[0] * y + sh[1] * z - sh[2] * x);
    float xx = x * x, yy = y * y, zz = z * z, xy = x * y, yz = y * z, xz = x * z;
    result += sh[3] * (SH_C2_0 * xy) + sh[4] * (SH_C2_1 * yz) +
        sh[5] * (SH_C2_2 * (2.0 * zz - xx - yy)) +
        sh[6] * (SH_C2_3 * xz) +
        sh[7] * (SH_C2_4 * (xx - yy));
    result += sh[8] * (SH_C3_0 * y * (3.0 * xx - yy)) +
        sh[9] * (SH_C3_1 * xy * z) +
        sh[10] * (SH_C3_2 * y * (4.0 * zz - xx - yy)) +
        sh[11] * (SH_C3_3 * z * (2.0 * zz - 3.0 * xx - 3.0 * yy)) +
        sh[12] * (SH_C3_4 * x * (4.0 * zz - xx - yy)) +
        sh[13] * (SH_C3_5 * z * (xx - yy)) +
        sh[14] * (SH_C3_6 * x * (xx - 3.0 * yy));
    return result;
}

void main() {
    // One fragment per splat: gl_FragCoord maps to the color-sidecar layout.
    float col = floor(gl_FragCoord.x);
    float row = floor(gl_FragCoord.y);
    float idx = row * 512.0 + col;

    if (idx >= resolve_info.splat_count) {
        fragColor = vec4(0.0);
        return;
    }

    vec4 base_color_srgb = fetchSidecar(u_color_texture, idx);
    vec3 sh[15];
    readSHData(idx, sh);

    vec3 sh_lighting = evalSH(normalize(resolve_info.view_dir), sh);
    vec3 final_srgb_rgb = max(base_color_srgb.rgb + sh_lighting, vec3(0.0));

    fragColor = vec4(final_srgb_rgb, base_color_srgb.a);
}
