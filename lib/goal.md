lib/
  renderer/
    renderer.dart              // Tiny façade: init / render(frame) / dispose; owns PassGraph & Registry
    pass_graph.dart            // Ordered list of passes; wires inputs/outputs each frame
  gl/
    caps.dart                  // ANGLE/WebGL ES capability probe → chosen formats & fallbacks
    resources.dart             // Resource wrappers (Program/Texture/Buffer/FBO) + ResourceRegistry + state cache
    shader_program.dart        // Compile/link cache keyed by Variant; builds shaders from chunks + defines
  data/
    splat_source.dart          // Upload & manage splat data texture (5 texels per splat); exposes count & dims
    order_texture.dart         // Manage order texture (R32UI or RGBA8 fallback) + uploads (sequential/sorted)
    workbuffer_store.dart      // Create/resize MRT FBO (2–4 attachments) and expose attachments for passes
  sorting/
    scheduler.dart             // Camera-motion gate + debounce + calls existing depth sorter; publishes results
  passes/
    background.dart            // Optional skydome/clear
    workbuffer_copy.dart       // Copy/normalize: write per-splat color/center/cov* into MRT
    splat_draw.dart            // Final draw: sample work buffer + order; instanced quads; blending
  materials/
    variants.dart              // Defines ShaderVariant (pass, mrt layout, order fmt, debug flags)
    shaders/
      common/*.glsl            // Shared math (gaussian, SH, packing, etc.)
      splat_main.vs.glsl
      splat_main.fs.glsl
      workbuffer_copy.vs.glsl
      workbuffer_copy.fs.glsl
  config/
    feature_flags.dart         // Toggles (enableWorkBuffer, mrtCount, debug viz, etc.)
