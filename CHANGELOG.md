## 0.3.0 - 2025-09-08

### 🏗️ Architecture Overhaul
* **BREAKING**: Complete restructure from monolithic to service-based architecture
* feat: new modular service-based renderer architecture with separated concerns
* feat: file restructuring - moved from `core/` to domain-specific directories
* feat: shader factory system for better shader management
* feat: render pass abstraction for extensible rendering pipeline

### 🚀 Performance & Rendering Improvements  
* feat: instanced rendering with batched draw calls (128 splats per instance)
* feat: alpha write control for bandwidth optimization 
* feat: maximum splat size limiting to prevent excessive overdraw
* feat: improved Mali GPU compatibility and Android rendering stability
* fix: coordinate system consistency across platforms (Android vs iOS)
* fix: vsync synchronization with Flutter's frame scheduling

### 🔧 Technical Enhancements
* feat: consolidated camera perspective logic with immutable camera model  
* feat: background sky dome refactored as proper render pass
* fix: improved texture format fallback (R32UI → RGBA32F)
* fix: vertex shader optimizations with conditional compilation
* fix: Android floating-point texture compatibility
* chore: comprehensive linting and code cleanup
* docs: added detailed renderer architecture documentation

### 📦 File Structure Changes
```
lib/
├── camera/          # Camera system (new)
├── data/           # GPU data management (new) 
├── files/          # File processing (moved from core/)
├── gl/             # WebGL utilities (new)
├── passes/         # Render passes (new)
├── perf/           # Performance monitoring (moved from core/)
├── renderer/       # Main renderer (new)
├── sorting/        # Depth sorting (moved from core/)
└── widgets/        # Flutter widgets
```

## 0.2.2 - 2025-08-31

* fix: code cleanup and optimization for better maintainability
* feat: Add backgrounds to 3D viewer

## 0.2.1 - 2025-08-22

* feat: make profiling optional for optimal performance (defaults to disabled)
* fix: improved FPS measurement accuracy with proper frame timing
* fix: GPU profiling cleanup and optimization
* fix: Resize function


## 0.2.0 - 2025-08-21

* feat: better texture packing with optimized atlas layout (5 texels per splat)
* feat: constants extraction and reorganization for better maintainability
* feat: GPU-side covariance computation for improved performance
* fix: vertex shader improvements with better packing/unpacking logic
* fix: remove old unused covariance calculation code
* fix: Mali GPU compatibility improvements

## 0.1.3 - 2025-06-25

* Use all SH coeffs.
* Fix mirroring of camera.
* Fix Mali GPU issues

## 0.1.2 - 2025-06-11

* Updated README.md to use demo.gif instead of toycar.png in Overview section.

## 0.1.1 - 2025-06-11

* Updated README.md with Acknowledgements, Basic Usage example, and License sections.
* Added LICENSE file.

## 0.1.0

- feat: initial commit 🎉
