import 'dart:io' show Platform;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;

/// Minimal replacement for `package:universal_platform`.
///
/// Uses [defaultTargetPlatform] (testable, web-safe) instead of `dart:io`
/// [Platform], which cannot compile for web. The `!kIsWeb` guard keeps
/// web builds from being misdetected as a native platform.
class AppPlatform {
  AppPlatform._();

  static bool get isWeb => kIsWeb;

  static bool get isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static bool get isIOS =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  static bool get isWindows =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  static bool get isLinux =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;

  static bool get isMacOS =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  static bool get isMobile => isAndroid || isIOS;

  static bool get isDesktop => isWindows || isLinux || isMacOS;
}
