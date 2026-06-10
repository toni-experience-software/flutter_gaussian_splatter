#version 460 core

uniform FrameInfo {
  mat4 projection;
  mat4 view;
  vec2 focal;
  vec2 viewport;
  float splat_count;
  float max_splat_size;
  float atlas_height;
  float order_height;
  float sidecar_height;
  float sh_height;
} frame_info;

uniform BatchInfo {
  float base_splat;
} batch_info;

uniform sampler2D u_texture;
uniform sampler2D u_order_texture;
uniform sampler2D u_quat_texture;
uniform sampler2D u_color_texture;
uniform sampler2D u_sh_texture;

in vec3 position;

out vec4 vColor;
out vec2 vPosition;

vec4 fetchTexel(sampler2D source, vec2 texel, vec2 size) {
    return texture(source, (texel + vec2(0.5)) / size);
}

vec4 fetchAtlas(float idx, float offset) {
    float col = mod(idx, 512.0);
    float row = floor(idx / 512.0);
    return fetchTexel(
        u_texture,
        vec2(col * 2.0 + offset, row),
        vec2(1024.0, frame_info.atlas_height));
}

vec4 fetchSidecar(sampler2D source, float idx) {
    return fetchTexel(
        source,
        vec2(mod(idx, 512.0), floor(idx / 512.0)),
        vec2(512.0, frame_info.sidecar_height));
}

vec4 fetchSH(float idx, float coefficientGroup) {
    float shIndex = idx * 12.0 + coefficientGroup;
    return fetchTexel(
        u_sh_texture,
        vec2(mod(shIndex, 512.0), floor(shIndex / 512.0)),
        vec2(512.0, frame_info.sh_height));
}

float decodeOrder(vec4 orderTexel) {
    vec4 bytes = floor(orderTexel * 255.0 + 0.5);
    return dot(bytes, vec4(1.0, 256.0, 65536.0, 16777216.0));
}

vec4 decodeQuaternion(vec4 packedQuat) {
    vec4 q = packedQuat * 255.0 - 128.0;
    return normalize(q);
}

vec4 unpackSH(vec4 packed) {
    return packed * 8.0 - 4.0;
}

void readSHData_reference(float idx, out vec3 sh[15], out float scale) {
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
    scale = 1.0;
}

void clipCorner(inout vec2 majorAxis, inout vec2 minorAxis, inout vec2 corner_uv, float alpha) {
    float clip = min(1.0, sqrt(-log(1.0 / 255.0 / alpha)) / 2.0);
    majorAxis *= clip;
    minorAxis *= clip;
    corner_uv *= clip;
}

vec3 prepareOutputFromGamma(vec3 gammaColor) {
    return gammaColor;
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

vec3 evalSH_reference(in vec3 dir, in vec3 sh[15]) {
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

mat3 quatToMat3(vec4 R) {
    vec4 R2 = R + R;
    float X = R2.x * R.w;
    vec4 Y = R2.y * R;
    vec4 Z = R2.z * R;
    float W = R2.w * R.w;
    return mat3(1.0 - Z.z - W, Y.z + X, Y.w - Z.x, Y.z - X, 1.0 - Y.y - W, Z.w + Y.x, Y.w + Z.x, Z.w - Y.x, 1.0 - Y.y - Z.z);
}

void main() {
    float orderIdx = floor(batch_info.base_splat + position.z + 0.5);
    vec2 corner_uv = position.xy;

    if (orderIdx >= frame_info.splat_count) {
        gl_Position = vec4(0.0, 0.0, 2.0, 1.0);
        return;
    }

    vec4 orderTexel = fetchTexel(
        u_order_texture,
        vec2(mod(orderIdx, 512.0), floor(orderIdx / 512.0)),
        vec2(512.0, frame_info.order_height));
    float idx = decodeOrder(orderTexel);

    if (idx >= frame_info.splat_count) {
        gl_Position = vec4(0.0, 0.0, 2.0, 1.0);
        return;
    }

    vec4 p0_data = fetchAtlas(idx, 0.0);
    vec4 p1_data = fetchAtlas(idx, 1.0);
    vec4 quat = decodeQuaternion(fetchSidecar(u_quat_texture, idx));
    vec4 base_color_srgb = fetchSidecar(u_color_texture, idx);

    vec3 worldPos = p0_data.xyz;
    vec3 scale = p1_data.xyz;

    vec4 cam_view_space = frame_info.view * vec4(worldPos, 1.0);
    vec4 pos2d = frame_info.projection * cam_view_space;

    if(-cam_view_space.z > 0.0) {
        gl_Position = vec4(0.0, 0.0, 2.0, 1.0);
        return;
    }

    pos2d.z = clamp(pos2d.z, -abs(pos2d.w), abs(pos2d.w));

    mat3 Rm = quatToMat3(quat);
    mat3 M = mat3(Rm[0] * scale.x, Rm[1] * scale.y, Rm[2] * scale.z);
    vec3 r0 = vec3(M[0][0], M[1][0], M[2][0]);
    vec3 r1 = vec3(M[0][1], M[1][1], M[2][1]);
    vec3 r2 = vec3(M[0][2], M[1][2], M[2][2]);

    float c00 = dot(r0, r0);
    float c01 = dot(r0, r1);
    float c02 = dot(r0, r2);
    float c11 = dot(r1, r1);
    float c12 = dot(r1, r2);
    float c22 = dot(r2, r2);
    mat3 Vrk = 4.0 * mat3(c00, c01, c02, c01, c11, c12, c02, c12, c22);

    float invz = 1.0 / cam_view_space.z;
    float invz2 = invz * invz;
    float Jx = frame_info.focal.x * invz;
    float Jy = frame_info.focal.y * invz;
    mat3 J = mat3(Jx, 0.0, -(frame_info.focal.x * cam_view_space.x) * invz2, 0.0, Jy, -(frame_info.focal.y * cam_view_space.y) * invz2, 0.0, 0.0, 0.0);

    mat3 T = transpose(mat3(frame_info.view)) * J;
    mat3 cov2d = transpose(T) * Vrk * T;

    float d1 = cov2d[0][0] + 0.3;
    float od = cov2d[0][1];
    float d2 = cov2d[1][1] + 0.3;
    float mid = 0.5 * (d1 + d2);
    float rad = length(vec2((d1 - d2) * 0.5, od));
    float l1 = mid + rad;
    float l2 = max(mid - rad, 0.1);
    float s1 = sqrt(max(0.0, 2.0 * l1));
    float s2 = sqrt(max(0.0, 2.0 * l2));

    if(s1 < 2.0 && s2 < 2.0) {
        gl_Position = vec4(0.0, 0.0, 2.0, 1.0);
        return;
    }

    if (max(s1, s2) > frame_info.max_splat_size) {
        gl_Position = vec4(0.0, 0.0, 2.0, 1.0);
        return;
    }

    vec2 diagVec = normalize(vec2(od, l1 - d1));
    vec2 majorAxis = min(s1, 1024.0) * 2.0 * diagVec;
    vec2 minorAxis = min(s2, 1024.0) * 2.0 * vec2(diagVec.y, -diagVec.x);

    vec2 c = pos2d.ww / frame_info.viewport;
    float margin = 2.0;
    float max_axis_length = max(length(majorAxis), length(minorAxis));
    if(any(greaterThan(abs(pos2d.xy) - vec2(max_axis_length * margin) * c, pos2d.ww))) {
        gl_Position = vec4(0.0, 0.0, 2.0, 1.0);
        return;
    }

    vec3 base_color_linear = base_color_srgb.rgb;
    vec3 sh[15];
    float shScale;
    readSHData_reference(idx, sh, shScale);

    vec3 dir_sh = normalize((cam_view_space.xyz / cam_view_space.w) * mat3(frame_info.view));
    vec3 sh_lighting = evalSH_reference(dir_sh, sh);
    vec3 sum_linear = base_color_linear + sh_lighting;
    vec3 final_srgb_rgb = prepareOutputFromGamma(max(sum_linear, vec3(0.0)));

    clipCorner(majorAxis, minorAxis, corner_uv, base_color_srgb.a);

    vec2 offsetClip = (corner_uv.x * majorAxis + corner_uv.y * minorAxis) * c;
    gl_Position = vec4(pos2d.xy + offsetClip, pos2d.z, pos2d.w);

    vColor = vec4(final_srgb_rgb, base_color_srgb.a);
    vPosition = corner_uv;
}
