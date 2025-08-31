#version 300 es
void main() {
  const vec2 v[3] = vec2[3](
    vec2(-1.0, -1.0),
    vec2( 3.0, -1.0),
    vec2(-1.0,  3.0)
  );
  gl_Position = vec4(v[gl_VertexID], 0.0, 1.0);
}
