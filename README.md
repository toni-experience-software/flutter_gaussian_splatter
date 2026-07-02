# Flutter Gaussian Splatter

[![Powered by Mason][mason_badge]][mason_link]
[![lints by lintervention][lintervention_badge]][lintervention_link]

---

**🚧 Early Developer Preview 🚧**

This package is an early developer preview and is **not yet intended for production use**.

---

Flutter Gaussian Splatter renders 3D Gaussian Splatting scenes natively in Flutter. It is built on [Flutter GPU][flutter_gpu_link], Flutter's low-level graphics API on top of the [Impeller][impeller_link] rendering engine, no platform views, no external graphics runtime, just a regular Flutter widget.

## Overview

This project provides a Flutter widget for rendering 3D scenes using Gaussian Splatting. Splat data is loaded from `.ply` files, depth-sorted on a background isolate, and drawn through Flutter GPU with spherical-harmonics lighting.

![Demo of Flutter Gaussian Splatter](doc/demo.gif)

## Requirements

*   Flutter **3.44 or newer** (stable channel). Flutter GPU and Dart build hooks, both of which this package relies on, are available on stable as of 3.44.
*   A platform where Impeller and Flutter GPU are available: **iOS**, **Android**, or **macOS**. Windows, Linux, and web are not supported yet.

The package compiles its shaders into a Flutter GPU shader bundle automatically at build time via a Dart build hook, you don't need to configure anything for that.

## Enabling Flutter GPU

Flutter GPU ships with the stable channel but is **opt-in per platform**. Enable it in the app that consumes this package:

**iOS**, add to `ios/Runner/Info.plist` (Impeller is already the default renderer on iOS):

```xml
<key>FLTEnableFlutterGPU</key>
<true/>
```

**macOS**, add to `macos/Runner/Info.plist` (Impeller also needs to be switched on):

```xml
<key>FLTEnableImpeller</key>
<true/>
<key>FLTEnableFlutterGPU</key>
<true/>
```

**Android**, add inside the `<application>` element of `android/app/src/main/AndroidManifest.xml`:

```xml
<meta-data
    android:name="io.flutter.embedding.android.EnableFlutterGPU"
    android:value="true" />
```

These flags are permitted in release builds. Note that the platform folders of the bundled `example/` app are not checked in, if you run it, generate them with `flutter create .` inside `example/` and then add the flags above.

## Basic Usage Example

To use the `GaussianSplatterWidget`, import the package and add the widget to your Flutter application. You'll need to provide the path to your `.ply` asset.

```dart
import 'package:flutter/material.dart';
import 'package:flutter_gaussian_splatter/widgets/gaussian_splatter_widget.dart';

class MyAwesomeApp extends StatelessWidget {
  const MyAwesomeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Gaussian Splatter Demo'),
        ),
        body: const GaussianSplatterWidget(
          assetPath: 'assets/your_model.ply', // Replace with your asset path
          // Optional:
          // backgroundAssetPath: 'assets/sky.jpg', // 360° background sphere
          // highQualitySH: true, // full per-splat SH evaluation every frame
          // showStats: true,
        ),
      ),
    );
  }
}
```

Make sure to add your `.ply` file to your `pubspec.yaml` assets:
```yaml
flutter:
  assets:
    - assets/your_model.ply # Or your specific asset path
```

By default, spherical harmonics are resolved once per splat using a global view direction, which is significantly faster. Set `highQualitySH: true` for full per-splat, view-dependent SH evaluation.

## Compatibility

The Flutter GPU renderer has been tested primarily on Apple Silicon Macs and modern iPhones. Android is expected to work wherever Impeller is supported, but has seen less testing on this backend so far. If you experience any problems, please [open an issue][new_issue_link] on our GitHub repository.

## Call for Contribution

This is an open-source project, and we welcome contributions from the community! Whether it's bug fixes, feature enhancements, or documentation improvements, your help is valuable. Feel free to fork the repository, make your changes, and submit a pull request.

## Installation 💻

**❗ In order to start using Flutter Gaussian Splatter you must have the [Flutter SDK][flutter_install_link] installed on your machine.**

Install via `flutter pub add`:

```sh
flutter pub add flutter_gaussian_splatter
```

## Acknowledgements

This project is highly inspired by the work done on [antimatter15/splat](https://github.com/antimatter15/splat).

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

[mason_link]: https://github.com/felangel/mason
[mason_badge]: https://img.shields.io/endpoint?url=https%3A%2F%2Ftinyurl.com%2Fmason-badge
[lintervention_link]: https://github.com/whynotmake-it/lintervention
[lintervention_badge]: https://img.shields.io/badge/lints_by-lintervention-3A5A40
[flutter_install_link]: https://docs.flutter.dev/get-started/install
[flutter_gpu_link]: https://blog.flutter.dev/getting-started-with-flutter-gpu-f33d497b7c11
[impeller_link]: https://docs.flutter.dev/perf/impeller
[new_issue_link]: https://github.com/toni-experience-software/flutter_gaussian_splatter/issues/new
[github_actions_link]: https://docs.github.com/en/actions/learn-github-actions
