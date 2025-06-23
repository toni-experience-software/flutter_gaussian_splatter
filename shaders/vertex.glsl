#version 300 es
precision highp float;
precision highp int;

uniform highp sampler2D u_texture; // Gaussian splat data texture (RGBA32F format)
uniform mat4 projection, view;
uniform vec2 focal;
uniform vec2 viewport;

in vec2 position;       // Quad corner coordinates (-1 to 1)
in float index;         // Gaussian splat index

out vec4 vColor;
out vec2 vPosition;     // Quad corner coordinates for fragment shader

// Unpacks a 16-bit IEEE 754 half-precision float from uint
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

// Unpacks two 16-bit half-precision floats from a single uint32
vec2 unpackHalf2x16_from_uint(uint val) {
    return vec2(unpackHalf(val & 0xFFFFu), unpackHalf(val >> 16u));
}

// Unpacks 4 signed bytes from uint32 to vec4 range [-4, 4)
vec4 unpack8888s(in uint bits) {
    return vec4((uvec4(bits) >> uvec4(0u, 8u, 16u, 24u)) & 0xffu) * (8.0f / 255.0f) - 4.0f;
}

// Unpacks 4 unsigned bytes from uint32 to vec4 range [0, 1]
vec4 unpack8888(uint bits) {
    return vec4(float(bits >> 24u) / 255.0f, float((bits >> 16u) & 0xffu) / 255.0f, float((bits >> 8u) & 0xffu) / 255.0f, float(bits & 0xffu) / 255.0f);
}

// Reads spherical harmonics coefficients from texture data
// Fetches and unpacks SH data for all 15 coefficients across 3 bands
void readSHData_reference(int idx, out vec3 sh[15], out float scale) {
    ivec2 base_uv = ivec2((idx & 0xff) << 3, idx >> 8);

    // Fetch SH data from texture at offsets 2, 3, 4
    highp vec4 f_sh_0 = texelFetch(u_texture, base_uv + ivec2(2, 0), 0);
    highp vec4 f_sh_1 = texelFetch(u_texture, base_uv + ivec2(3, 0), 0);
    highp vec4 f_sh_2 = texelFetch(u_texture, base_uv + ivec2(4, 0), 0);

    // Convert float data to uint for unpacking
    uvec4 shData0 = uvec4(floatBitsToUint(f_sh_0.x), floatBitsToUint(f_sh_0.y), floatBitsToUint(f_sh_0.z), floatBitsToUint(f_sh_0.w));
    uvec4 shData1 = uvec4(floatBitsToUint(f_sh_1.x), floatBitsToUint(f_sh_1.y), floatBitsToUint(f_sh_1.z), floatBitsToUint(f_sh_1.w));
    uvec4 shData2 = uvec4(floatBitsToUint(f_sh_2.x), floatBitsToUint(f_sh_2.y), floatBitsToUint(f_sh_2.z), floatBitsToUint(f_sh_2.w));

    // Unpack signed byte data for RGB channels
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

    // Map unpacked data to SH coefficients array
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
    scale = 1.0f;
}

// Decodes SH0 coefficients from byte values to floating point
// Converts from encoded format: rByte = ((0.5 + SH_C0 * fDc0) * 255)
// To decoded format: fDc0 = (rByte/255.0 - 0.5) / SH_C0
float byteToSH0Coeff(uint word, int byteIdx) {
    float byteVal = float((word >> uint(byteIdx * 8)) & 0xffu);
    const float SH_C0 = 0.28209479177387814f; // Spherical harmonics Y(0,0) coefficient
    return (byteVal / 255.0f - 0.5f) / SH_C0;
}

// Clips ellipse axes and UV coordinates based on alpha value
// Prevents rendering artifacts by constraining splat size based on opacity
void clipCorner(inout vec2 majorAxis, inout vec2 minorAxis, inout vec2 corner_uv, float alpha) {
    float clip = min(1.0f, sqrt(-log(1.0f / 255.0f / alpha)) / 2.0f);
    majorAxis *= clip;
    minorAxis *= clip;
    corner_uv *= clip;
}

// Prepares final color output from gamma-corrected input
// Currently passes through without modification for simplified SRGB pipeline
vec3 prepareOutputFromGamma(vec3 gammaColor) {
    return gammaColor;
}


// Spherical harmonics normalization constants
// Used for evaluating SH basis functions up to degree 3 (4 bands)
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

// Evaluates spherical harmonics lighting for a given direction
// Computes color contribution from SH coefficients up to degree 3
vec3 evalSH_reference(in vec3 dir, in vec3 sh[15]) {
    float x = dir.x;
    float y = dir.y;
    float z = dir.z;
    vec3 result = SH_C1 * (-sh[0] * y + sh[1] * z - sh[2] * x);
    float xx = x * x;
    float yy = y * y;
    float zz = z * z;
    float xy = x * y;
    float yz = y * z;
    float xz = x * z;
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

// Converts quaternion to 3x3 rotation matrix
// Input quaternion format: (x, y, z, w)
mat3 quatToMat3(vec4 R) {
    float x = R.x;
    float y = R.y;
    float z = R.z;
    float w = R.w;
    return mat3(1.0f - 2.0f * (z * z + w * w), 2.0f * (y * z + x * w), 2.0f * (y * w - x * z), 2.0f * (y * z - x * w), 1.0f - 2.0f * (y * y + w * w), 2.0f * (z * w + x * y), 2.0f * (y * w + x * z), 2.0f * (z * w - x * y), 1.0f - 2.0f * (y * y + z * z));
}

void main() {
    int idx = int(index);
    ivec2 base_uv = ivec2((idx & 0xff) << 3, idx >> 8);

    // Fetch position and auxiliary data from texture
    highp vec4 p0_data = texelFetch(u_texture, base_uv, 0);
    vec3 worldPos = p0_data.xyz;
    highp vec4 p1_data = texelFetch(u_texture, base_uv + ivec2(1, 0), 0);

    // Read spherical harmonics coefficients for lighting
    vec3 sh[15];
    float scale;
    readSHData_reference(idx, sh, scale);

    // Transform to camera and projection space
    vec4 cam_view_space = view * vec4(worldPos, 1.0f);
    vec4 pos2d = projection * cam_view_space;

    // Cull splats behind camera (conservative check)
    if(-cam_view_space.z > 0.0f) {
        gl_Position = vec4(0.0f, 0.0f, 2.0f, 1.0f);
        return;
    }

    // Clamp depth to prevent z-fighting
    pos2d.z = clamp(pos2d.z, -abs(pos2d.w), abs(pos2d.w));

    vec2 screenPos = pos2d.xy / pos2d.w;

    // === Covariance Matrix Computation ===
    // Extract 3D covariance matrix elements stored as half-precision floats
    highp uint packed_cov_term1 = floatBitsToUint(p1_data.r);
    highp uint packed_cov_term2 = floatBitsToUint(p1_data.g);
    highp uint packed_cov_term3 = floatBitsToUint(p1_data.b);
    vec2 u1 = unpackHalf2x16_from_uint(packed_cov_term1);
    vec2 u2 = unpackHalf2x16_from_uint(packed_cov_term2);
    vec2 u3 = unpackHalf2x16_from_uint(packed_cov_term3);

    // Reconstruct 3D covariance matrix from packed elements
    mat3 Vrk = mat3(u1.x, u1.y, u2.x, u1.y, u2.y, u3.x, u2.x, u3.x, u3.y);

    // Compute Jacobian for perspective projection
    mat3 J = mat3(focal.x / cam_view_space.z, 0.f, -(focal.x * cam_view_space.x) / (cam_view_space.z * cam_view_space.z), 0.f, focal.y / cam_view_space.z, -(focal.y * cam_view_space.y) / (cam_view_space.z * cam_view_space.z), 0.f, 0.f, 0.f);
    mat3 T = transpose(mat3(view)) * J;
    // Project 3D covariance to 2D screen space using view-projection transform
    mat3 cov2d = transpose(T) * Vrk * T;


    // Extract 2D covariance matrix elements and add regularization
    float diagonal1 = cov2d[0][0] + 0.3f;
    float offDiagonal = cov2d[0][1];
    float diagonal2 = cov2d[1][1] + 0.3f;

    // Compute eigenvalues of 2D covariance matrix
    float mid = 0.5f * (diagonal1 + diagonal2);
    float radius_val = length(vec2((diagonal1 - diagonal2) * 0.5f, offDiagonal));

    float lambda1 = mid + radius_val;     // Major axis eigenvalue
    float lambda2 = max(mid - radius_val, 0.1f);   // Minor axis eigenvalue (clamped)

    // Cull very small splats
    if(sqrt(2.0f * lambda1) < 2.0f && sqrt(2.0f * lambda2) < 2.0f) {
        gl_Position = vec4(0.0f, 0.0f, 2.0f, 1.0f);
        return;
    }

    // Compute ellipse axes from eigenvalues and eigenvectors
    vec2 diagonalVector = normalize(vec2(offDiagonal,
                                     lambda1 - diagonal1));
    vec2 majorAxis = min(sqrt(2.0f * lambda1), 1024.0f) * diagonalVector;
    vec2 minorAxis = min(sqrt(2.0f * lambda2), 1024.0f) * vec2(diagonalVector.y, -diagonalVector.x);

    // Frustum culling with conservative margin
    vec2 c = pos2d.ww / viewport;
    float margin = 2.0f; // Conservative margin for safety
    float max_axis_length = max(length(majorAxis), length(minorAxis));
    if(any(greaterThan(abs(pos2d.xy) - vec2(max_axis_length * margin) * c, pos2d.ww))) {
        gl_Position = vec4(0.0f, 0.0f, 2.0f, 1.0f);
        return;
    }

    // === Color and Lighting Computation ===
    // Unpack base color from alpha channel
    highp uint packedColorBits = floatBitsToUint(p1_data.a);
    vec4 base_color_srgb = vec4(float(packedColorBits & 0xffu), float((packedColorBits >> 8u) & 0xffu), float((packedColorBits >> 16u) & 0xffu), float((packedColorBits >> 24u) & 0xffu)) / 255.0f;

    // Base color is already encoded with SH0 coefficient, treat as linear
    vec3 base_color_linear = base_color_srgb.rgb;

    // Compute view direction for spherical harmonics evaluation
    vec4 centerView = view * vec4(worldPos, 1.0f);
    vec3 center_view = centerView.xyz / centerView.w;
    mat4 center_modelView = view;
    vec3 dir_sh = normalize(center_view * mat3(center_modelView));

    // Evaluate spherical harmonics lighting
    vec3 sh_lighting = evalSH_reference(dir_sh, sh);

    // Combine base color with SH lighting
    vec3 sum_linear = base_color_linear + sh_lighting;

    // Prepare final output color
    vec3 final_srgb_rgb = prepareOutputFromGamma(max(sum_linear, vec3(0.0f)));

    // Apply alpha-based corner clipping
    vec2 corner_uv = position;
    clipCorner(majorAxis, minorAxis, corner_uv, base_color_srgb.a);

    // Transform quad corner to clip space
    vec2 offsetClip = (corner_uv.x * majorAxis +
        corner_uv.y * minorAxis) * c;

    gl_Position = vec4(pos2d.xy + offsetClip, pos2d.z, pos2d.w);

    vColor = vec4(final_srgb_rgb, base_color_srgb.a);
    vPosition = corner_uv;

}