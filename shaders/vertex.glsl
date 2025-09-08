#version 300 es
precision highp float;
precision highp int;

uniform highp sampler2D u_texture; // Gaussian splat data texture (RGBA32F format)
uniform mat4 projection, view;
uniform vec2 focal;
uniform vec2 viewport;
// Order texture storing sorted indices.
// Uses R32UI (integer) when supported, RGBA32F (float) fallback otherwise.
// The texture has width equal to GsConst.splatsPerRow (512).
#ifdef USE_INTEGER_TEXTURE
uniform highp usampler2D u_orderTexture;
#else
uniform highp sampler2D u_orderTexture;
#endif
// Maximum allowed ellipse radius in pixels before culling.  Splats whose
// projected major or minor axis exceeds this threshold are discarded.
uniform float uMaxSplatSize;

in vec3 position;       // Quad corner coordinates (-1 to 1) with local offset in .z
// Base index computed from gl_InstanceID - no attribute needed

out mediump vec4 vColor;
out mediump vec2 vPosition;     // Quad corner coordinates for fragment shader

uniform int splatCount;

// ---------- helpers unchanged ----------
float unpackHalf(uint half_val) {
    uint sign = (half_val >> 15u) & 0x0001u;
    uint exponent = (half_val >> 10u) & 0x001Fu;
    uint mantissa = half_val & 0x03FFu;

    if(exponent == 0u) {
        if(mantissa == 0u)
            return sign == 1u ? -0.0f : 0.0f;
        return float(sign == 1u ? -1 : 1) * float(mantissa) * exp2(-24.0f);
    } else if(exponent == 31u) {
        return sign == 1u ? -1.0f / 0.0f : 1.0f / 0.0f;
    }
    float result = float(mantissa | 0x0400u) * exp2(float(int(exponent) - 15 - 10));
    return sign == 1u ? -result : result;
}

vec2 unpackHalf2x16_from_uint(uint val) {
    return vec2(unpackHalf(val & 0xFFFFu), unpackHalf(val >> 16u));
}

vec4 unpack8888s(in uint bits) {
    return vec4((uvec4(bits) >> uvec4(0u, 8u, 16u, 24u)) & 0xffu) * (8.0f / 255.0f) - 4.0f;
}

vec4 unpack8888(uint bits) {
    return vec4(float(bits >> 24u) / 255.0f, float((bits >> 16u) & 0xffu) / 255.0f, float((bits >> 8u) & 0xffu) / 255.0f, float(bits & 0xffu) / 255.0f);
}

// Decodes quaternion from packed byte format
vec4 decodeQuaternion(uint packedQuat) {
    float x = float(packedQuat & 0xffu) - 128.0f;
    float y = float((packedQuat >> 8u) & 0xffu) - 128.0f;
    float z = float((packedQuat >> 16u) & 0xffu) - 128.0f;
    float w = float((packedQuat >> 24u) & 0xffu) - 128.0f;
    float invLen = inversesqrt(max(1e-12f, x * x + y * y + z * z + w * w));
    return vec4(x, y, z, w) * invLen;
}

// ---------- SH read (only base_uv changed to 5-texel layout) ----------
void readSHData_reference(int idx, out vec3 sh[15], out float scale) {
    //(idx & 0x1ff) * 5 , idx >> 9
    ivec2 base_uv = ivec2((idx & 0x1ff) * 5, idx >> 9);

    highp vec4 f_sh_0 = texelFetch(u_texture, base_uv + ivec2(2, 0), 0);
    highp vec4 f_sh_1 = texelFetch(u_texture, base_uv + ivec2(3, 0), 0);
    highp vec4 f_sh_2 = texelFetch(u_texture, base_uv + ivec2(4, 0), 0);

    uvec4 shData0 = uvec4(floatBitsToUint(f_sh_0.x), floatBitsToUint(f_sh_0.y), floatBitsToUint(f_sh_0.z), floatBitsToUint(f_sh_0.w));
    uvec4 shData1 = uvec4(floatBitsToUint(f_sh_1.x), floatBitsToUint(f_sh_1.y), floatBitsToUint(f_sh_1.z), floatBitsToUint(f_sh_1.w));
    uvec4 shData2 = uvec4(floatBitsToUint(f_sh_2.x), floatBitsToUint(f_sh_2.y), floatBitsToUint(f_sh_2.z), floatBitsToUint(f_sh_2.w));

    vec4 r0 = unpack8888s(shData0.x);
    vec4 r1 = unpack8888s(shData0.y);
    vec4 r2 = unpack8888s(shData0.z);
    vec4 r3 = unpack8888s(shData0.w);
    vec4 g0 = unpack8888s(shData1.x);
    vec4 g1 = unpack8888s(shData1.y);
    vec4 g2 = unpack8888s(shData1.z);
    vec4 g3 = unpack8888s(shData1.w);
    vec4 b0 = unpack8888s(shData2.x);
    vec4 b1 = unpack8888s(shData2.y);
    vec4 b2 = unpack8888s(shData2.z);
    vec4 b3 = unpack8888s(shData2.w);

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
    scale = 1.0f; // unchanged; DC (SH0) lives in base color
}

float byteToSH0Coeff(uint word, int byteIdx) {
    float byteVal = float((word >> uint(byteIdx * 8)) & 0xffu);
    const float SH_C0 = 0.28209479177387814f;
    return (byteVal / 255.0f - 0.5f) / SH_C0;
}

void clipCorner(inout vec2 majorAxis, inout vec2 minorAxis, inout vec2 corner_uv, float alpha) {
    float clip = min(1.0f, sqrt(-log(1.0f / 255.0f / alpha)) / 2.0f);
    majorAxis *= clip;
    minorAxis *= clip;
    corner_uv *= clip;
}

vec3 prepareOutputFromGamma(vec3 gammaColor) {
    return gammaColor;
}

// ---------- SH eval unchanged ----------
#define SH_C1 0.4886025119029199f
#define SH_C2_0 1.0925484305920792f
#define SH_C2_1 -1.0925484305920792f
#define SH_C2_2 0.31539156525252005f
#define SH_C2_3 -1.0925484305920792f
#define SH_C2_4 0.5462742152960396f
#define SH_C3_0 -0.5900435899266435f
#define SH_C3_1 2.890611442640554f
#define SH_C3_2 -0.4570457994644658f
#define SH_C3_3 0.3731763325901154f
#define SH_C3_4 -0.4570457994644658f
#define SH_C3_5 1.445305721320277f
#define SH_C3_6 -0.5900435899266435f

vec3 evalSH_reference(in vec3 dir, in vec3 sh[15]) {
    float x = dir.x, y = dir.y, z = dir.z;
    vec3 result = SH_C1 * (-sh[0] * y + sh[1] * z - sh[2] * x);
    float xx = x * x, yy = y * y, zz = z * z, xy = x * y, yz = y * z, xz = x * z;
    result += sh[3] * (SH_C2_0 * xy) + sh[4] * (SH_C2_1 * yz) +
        sh[5] * (SH_C2_2 * (2.0f * zz - xx - yy)) +
        sh[6] * (SH_C2_3 * xz) +
        sh[7] * (SH_C2_4 * (xx - yy));
    result += sh[8] * (SH_C3_0 * y * (3.0f * xx - yy)) +
        sh[9] * (SH_C3_1 * xy * z) +
        sh[10] * (SH_C3_2 * y * (4.0f * zz - xx - yy)) +
        sh[11] * (SH_C3_3 * z * (2.0f * zz - 3.0f * xx - 3.0f * yy)) +
        sh[12] * (SH_C3_4 * x * (4.0f * zz - xx - yy)) +
        sh[13] * (SH_C3_5 * z * (xx - yy)) +
        sh[14] * (SH_C3_6 * x * (xx - 3.0f * yy));
    return result;
}

mat3 quatToMat3(vec4 R) {
    // Vectorized quaternion->matrix
    vec4 R2 = R + R;
    float X = R2.x * R.w;
    vec4 Y = R2.y * R;
    vec4 Z = R2.z * R;
    float W = R2.w * R.w;

    // Column-major mat3 constructor
    return mat3(1.0f - Z.z - W, Y.z + X, Y.w - Z.x, Y.z - X, 1.0f - Y.y - W, Z.w + Y.x, Y.w + Z.x, Z.w - Y.x, 1.0f - Y.y - Z.z);
}

void main() {
    // Compute the absolute index into the order texture using gl_InstanceID.
    // Each instance draws 128 splats, so base = gl_InstanceID * 128.
    // Add local offset from position.z to get the final index.
    int orderIdx = gl_InstanceID * 128 + int(position.z + 0.5);

    // If this vertex references an entry beyond the number of splats, push it
    // behind the far plane.  This culls extra vertices in the final batch.
    if (orderIdx >= splatCount) {
        gl_Position = vec4(0.0f, 0.0f, 2.0f, 1.0f);
        return;
    }

    // Lookup the actual splat index from the order texture.
    // Compute the texel coordinates by splitting orderIdx into low 9 bits (x) and the
    // remaining bits (y). The texture width (512) matches GsConst.splatsPerRow.
    const int ORDER_TEX_MASK = 0x1ff; // 512 - 1
    int orderX = orderIdx & ORDER_TEX_MASK;
    int orderY = orderIdx >> 9;
    
    int idx;
#ifdef USE_INTEGER_TEXTURE
    // Fetch from R32UI texture
    uint uid = texelFetch(u_orderTexture, ivec2(orderX, orderY), 0).r;
    idx = int(uid);
#else
    // Fetch from RGBA32F texture (fallback)
    float fid = texelFetch(u_orderTexture, ivec2(orderX, orderY), 0).r;
    idx = int(fid + 0.5); // Round to nearest integer
#endif

    // If the fetched index is out of bounds (should not happen but check), cull
    if (idx >= splatCount) {
        gl_Position = vec4(0.0f, 0.0f, 2.0f, 1.0f);
        return;
    }

    // base_uv for 5-texel layout.  After resolving the actual splat index we
    // compute the horizontal coordinate using the low 9 bits (masked by
    // 0x1ff) and the vertical coordinate using the high bits.  Each splat
    // occupies 5 texels horizontally.
    ivec2 base_uv = ivec2((idx & 0x1ff) * 5, idx >> 9);

    // Fetch P0 and P1 (pos/quat, scale/color)
    highp vec4 p0_data = texelFetch(u_texture, base_uv + ivec2(0, 0), 0); // pos.xyz + quat (packed u32)
    highp vec4 p1_data = texelFetch(u_texture, base_uv + ivec2(1, 0), 0); // scale.xyz + color (packed u32)

    vec3 worldPos = p0_data.xyz;

    uint packedQuat = floatBitsToUint(p0_data.w);
    vec4 quat = decodeQuaternion(packedQuat);

    vec3 scale = p1_data.xyz;

    // SH

    // Camera transform
    vec4 cam_view_space = view * vec4(worldPos, 1.0f);
    vec4 pos2d = projection * cam_view_space;

    if(-cam_view_space.z > 0.0f) {
        gl_Position = vec4(0.0f, 0.0f, 2.0f, 1.0f);
        return;
    }

    pos2d.z = clamp(pos2d.z, -abs(pos2d.w), abs(pos2d.w));
    vec2 screenPos = pos2d.xy / pos2d.w;

    // --- covariance without mat-muls ---
    // M = R * S  -> scale the *columns* of R by scale.{x,y,z}
    mat3 Rm = quatToMat3(quat);
    mat3 M = mat3(Rm[0] * scale.x,   // column 0
    Rm[1] * scale.y,   // column 1
    Rm[2] * scale.z);  // column 2

    // rows of M (since GLSL is column-major)
    vec3 r0 = vec3(M[0][0], M[1][0], M[2][0]);
    vec3 r1 = vec3(M[0][1], M[1][1], M[2][1]);
    vec3 r2 = vec3(M[0][2], M[1][2], M[2][2]);

    float c00 = dot(r0, r0);
    float c01 = dot(r0, r1);
    float c02 = dot(r0, r2);
    float c11 = dot(r1, r1);
    float c12 = dot(r1, r2);
    float c22 = dot(r2, r2);

    mat3 Vrk = 4.0f * mat3(c00, c01, c02, c01, c11, c12, c02, c12, c22);

   // --- drop-in replacement: cheaper Jacobian, eigen, axes, cull, and dir_sh reuse ---

// reuse z reciprocals instead of dividing multiple times
    float invz = 1.0f / cam_view_space.z;
    float invz2 = invz * invz;

// same Jacobian as before, but with reused terms
    float Jx = focal.x * invz;
    float Jy = focal.y * invz;

    mat3 J = mat3(Jx, 0.0f, -(focal.x * cam_view_space.x) * invz2, 0.0f, Jy, -(focal.y * cam_view_space.y) * invz2, 0.0f, 0.0f, 0.0f);

// same T and cov2d
    mat3 T = transpose(mat3(view)) * J;
    mat3 cov2d = transpose(T) * Vrk * T;

    // eigenvalues (unchanged math)
    float d1 = cov2d[0][0] + 0.3f;
    float od = cov2d[0][1];
    float d2 = cov2d[1][1] + 0.3f;

    float mid = 0.5f * (d1 + d2);
    float rad = length(vec2((d1 - d2) * 0.5f, od));

    float l1 = mid + rad;
    float l2 = max(mid - rad, 0.1f);

    // precompute radii once (saves 2 extra sqrt calls)
    float s1 = sqrt(max(0.0f, 2.0f * l1));
    float s2 = sqrt(max(0.0f, 2.0f * l2));

    // early out: both axes smaller than 2 px
    if(s1 < 2.0f && s2 < 2.0f) {
        gl_Position = vec4(0.0f, 0.0f, 2.0f, 1.0f);
        return;
    }

    // Cull splats whose projected radius exceeds a maximum threshold.
    // A very large ellipse implies that the splat covers the entire
    // viewport and will result in significant overdraw.  By discarding
    // such splats we approximate the behaviour of the work‑buffer
    // pipeline at close distances.  The threshold is provided via
    // uniform uMaxSplatSize.
    if (max(s1, s2) > uMaxSplatSize) {
        gl_Position = vec4(0.0f, 0.0f, 2.0f, 1.0f);
        return;
    }

    vec2 diagVec = normalize(vec2(od, l1 - d1));
    // Compensate for coordinate system change: [-2,2] → [-1,1] requires 2x scale
    vec2 majorAxis = min(s1, 1024.0f) * 2.0f * diagVec;
    vec2 minorAxis = min(s2, 1024.0f) * 2.0f * vec2(diagVec.y, -diagVec.x);

    // same frustum guard as your version
    vec2 c = pos2d.ww / viewport;
    float margin = 2.0f;
    float max_axis_length = max(length(majorAxis), length(minorAxis));
    if(any(greaterThan(abs(pos2d.xy) - vec2(max_axis_length * margin) * c, pos2d.ww))) {
        gl_Position = vec4(0.0f, 0.0f, 2.0f, 1.0f);
        return;
    }

    // ---------- Color + SH (lazy: only after we pass all early-outs) ----------
    uint packedColorBits = floatBitsToUint(p1_data.w);
    vec4 base_color_srgb = vec4(float(packedColorBits & 0xffu), float((packedColorBits >> 8u) & 0xffu), float((packedColorBits >> 16u) & 0xffu), float((packedColorBits >> 24u) & 0xffu)) / 255.0f;

    vec3 base_color_linear = base_color_srgb.rgb;

// Read SH now (after culling), not earlier
    vec3 sh[15];
    float shScale;
    readSHData_reference(idx, sh, shScale);

// Use existing cam_view_space to build SH view direction
    vec3 dir_sh = normalize((cam_view_space.xyz / cam_view_space.w) * mat3(view));

// SH eval + combine (DC term is in base color)
    vec3 sh_lighting = evalSH_reference(dir_sh, sh);
    vec3 sum_linear = base_color_linear + sh_lighting;
    vec3 final_srgb_rgb = prepareOutputFromGamma(max(sum_linear, vec3(0.0f)));

// Corner clipping & final position
    vec2 corner_uv = position.xy;
    clipCorner(majorAxis, minorAxis, corner_uv, base_color_srgb.a);

    vec2 offsetClip = (corner_uv.x * majorAxis + corner_uv.y * minorAxis) * c; // 'c' already computed above
    gl_Position = vec4(pos2d.xy + offsetClip, pos2d.z, pos2d.w);

    vColor = vec4(final_srgb_rgb, base_color_srgb.a);
    vPosition = corner_uv;
}
