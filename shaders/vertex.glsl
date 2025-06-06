 #version 300 es
      precision highp float;   // instead of mediump
      precision highp int;     // bit-ops work on ints/uints too

      uniform highp sampler2D u_texture;
      uniform mat4 projection, view;
      uniform vec2 focal;
      uniform vec2 viewport;

      in vec2 position;
      in float index;

      out vec4 vColor;
      out vec2 vPosition;

      // Converts a 16-bit half-float representation (as uint) to a 32-bit float
      float unpackHalf(uint half_val) {
          uint sign = (half_val >> 15u) & 0x0001u;
          uint exponent = (half_val >> 10u) & 0x001Fu;
          uint mantissa = half_val & 0x03FFu;
          
          if (exponent == 0u) { // Denormalized or zero
              if (mantissa == 0u) return sign == 1u ? -0.0 : 0.0;
              // Use manual calculation instead of ldexp
              return float(sign == 1u ? -1 : 1) * float(mantissa) * exp2(-24.0);
          } else if (exponent == 31u) { // Infinity or NaN
              return sign == 1u ? -1.0/0.0 : 1.0/0.0; // Infinity
          }
          
          // Normal case: use manual calculation instead of ldexp
          float result = float(mantissa | 0x0400u) * exp2(float(int(exponent) - 15 - 10));
          return sign == 1u ? -result : result;
      }

      // Unpacks two half-floats from a uint32
      vec2 unpackHalf2x16_from_uint(uint val) {
          return vec2(unpackHalf(val & 0xFFFFu), unpackHalf(val >> 16u));
      }

      void main () {
      int idx = int(index);   

          // Calculate texture coordinates for the center texel (first texel of each splat)
          // JavaScript: ivec2((uint(index) & 0x3ffu) << 1, uint(index) >> 10)
          int texWidth = 2048;
          int x = (idx & 1023) * 2;  // Exact JavaScript equivalent: (uint(index) & 0x3ffu) << 1
          int y = idx / 1024;        // Exact JavaScript equivalent: uint(index) >> 10
          
          // Sample the position data from P0 (first pixel of the pair)
          vec2 centerCoord = vec2(float(x) + 0.5, float(y) + 0.5) / vec2(float(texWidth), float(textureSize(u_texture, 0).y));
          highp vec4 positionData = texture(u_texture, centerCoord);
          
          // Extract world position from P0
          vec3 worldPos = positionData.xyz;
          
          // Simple perspective transform
          vec4 cam = view * vec4(worldPos, 1.0);
          vec4 pos2d = projection * cam;
          
        float clip = 1.2 * pos2d.w;
        if (pos2d.z < -clip || pos2d.x < -clip || pos2d.x > clip || pos2d.y < -clip || pos2d.y > clip) {
            gl_Position = vec4(0.0, 0.0, 2.0, 1.0);
            return;
        }
          
          // Convert to screen coordinates
          vec2 screenPos = pos2d.xy / pos2d.w;
          
          // Sample scale/covariance data from P1 (second pixel of the pair)
          vec2 scaleCoord = vec2(float(x + 1) + 0.5, float(y) + 0.5) / vec2(float(texWidth), float(textureSize(u_texture, 0).y));
          highp vec4 scaleData = texture(u_texture, scaleCoord);
          
          // Unpack half-float covariance data using proper half-float conversion
          // The CovarianceCalculator stores packed half-floats as float bit patterns
          // Each float contains two half-floats: high 16 bits and low 16 bits
          
          // Extract packed covariance components from RGB channels
          highp uint packed_cov_term1 = floatBitsToUint(scaleData.r);  // Contains 4*sigma00 (low), 4*sigma01 (high)
          highp uint packed_cov_term2 = floatBitsToUint(scaleData.g);  // Contains 4*sigma02 (low), 4*sigma11 (high)
          highp uint packed_cov_term3 = floatBitsToUint(scaleData.b);  // Contains 4*sigma12 (low), 4*sigma22 (high)
          
          // Unpack using proper half-float conversion functions
          vec2 u1 = unpackHalf2x16_from_uint(packed_cov_term1); // u1.x = 4*sigma00, u1.y = 4*sigma01
          vec2 u2 = unpackHalf2x16_from_uint(packed_cov_term2); // u2.x = 4*sigma02, u2.y = 4*sigma11
          vec2 u3 = unpackHalf2x16_from_uint(packed_cov_term3); // u3.x = 4*sigma12, u3.y = 4*sigma22
          
          // Reconstruct mat3 Vrk exactly as the JavaScript version does using these unpacked half-float components
          mat3 Vrk = mat3(u1.x, u1.y, u2.x, 
                          u1.y, u2.y, u3.x, 
                          u2.x, u3.x, u3.y);
          
          // Jacobian matrix for perspective projection (exact JavaScript)
          mat3 J = mat3(
              focal.x / cam.z, 0., -(focal.x * cam.x) / (cam.z * cam.z),
              0., -focal.y / cam.z, (focal.y * cam.y) / (cam.z * cam.z),
              0., 0., 0.
          );
          
          // Transform covariance to 2D (exact JavaScript)
          mat3 T = transpose(mat3(view)) * J;
          mat3 cov2d = transpose(T) * Vrk * T;
          
          // Eigenvalue decomposition for ellipse sizing (exact JavaScript)
          float mid = (cov2d[0][0] + cov2d[1][1]) / 2.0;
          float radius = length(vec2((cov2d[0][0] - cov2d[1][1]) / 2.0, cov2d[0][1]));
          float lambda1 = mid + radius;
          float lambda2 = mid - radius;
          
          // Skip splats with invalid eigenvalues
          if(lambda2 < 0.0) {
              gl_Position = vec4(0.0, 0.0, 2.0, 1.0);
              vColor = vec4(0.0);
              return;
          }
          
          // Calculate major and minor axes with proper scaling to match JavaScript reference
          vec2 diagonalVector = normalize(vec2(cov2d[0][1], lambda1 - cov2d[0][0]));
          vec2 majorAxis = min(sqrt(2.0 * lambda1), 1024.0) * diagonalVector ;  // Match JavaScript reference limit
          vec2 minorAxis = min(sqrt(2.0 * lambda2), 1024.0) * vec2(diagonalVector.y, -diagonalVector.x);  // Match JavaScript reference limit
          
          // Extract packed RGBA color from P1.A (second pixel, A component)
          // Extract packed color from P1.A component
          // Convert float back to uint32 bits and extract RGBA components exactly like JavaScript
          // JavaScript: vec4((cov.w) & 0xffu, (cov.w >> 8) & 0xffu, (cov.w >> 16) & 0xffu, (cov.w >> 24) & 0xffu) / 255.0
          highp uint packedColorBits = floatBitsToUint(scaleData.a);
          vec4 extractedColor = vec4(
              float(packedColorBits & 0xffu),         // R from bits 0-7
              float((packedColorBits >> 8u) & 0xffu),  // G from bits 8-15
              float((packedColorBits >> 16u) & 0xffu), // B from bits 16-23
              float((packedColorBits >> 24u) & 0xffu)  // A from bits 24-31
          ) / 255.0;
          
          // CRITICAL: Apply depth-based color attenuation exactly like JavaScript
          // JavaScript: vColor = clamp(pos2d.z/pos2d.w+1.0, 0.0, 1.0) * vec4(...)
          float depthAttenuation = clamp(pos2d.z/pos2d.w + 1.0, 0.0, 1.0);
          vColor = extractedColor * depthAttenuation;
          
          vPosition = position;

              // Render as simple fixed-size quads (10 pixel radius)

          
          // Final position: screen position + quad offset with ellipse-based sizing (exact JavaScript)
          vec2 vCenter = screenPos;
          gl_Position = vec4(
              vCenter
              + position.x * majorAxis / viewport
              + position.y * minorAxis / viewport, 
              0.0, 1.0
          );
      }