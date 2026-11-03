import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';

import '../utils/platform_detector.dart';

/// Fork: shared timing, curves and haptics for touch feedback, so presses,
/// long-presses and confirmations feel the same everywhere (modelled on
/// Plex's mobile app). TV and desktop get no haptics.
abstract final class ForkMotion {
  /// Press-in when a finger lands on something tappable.
  static const pressIn = Duration(milliseconds: 100);

  /// Spring back on release.
  static const release = Duration(milliseconds: 260);

  static const pressCurve = Curves.easeOutCubic;
  static const releaseCurve = Curves.easeOutBack;

  /// Scale while pressed, and once a long press is recognised.
  static const pressedScale = 0.96;
  static const longPressedScale = 0.93;

  /// Overlays that rise over the page (the AI composer, sheets): in with
  /// M3's emphasized-decelerate, out faster with emphasized-accelerate.
  static const sheetIn = Duration(milliseconds: 260);
  static const sheetOut = Duration(milliseconds: 200);
  static const enterCurve = Easing.emphasizedDecelerate;
  static const exitCurve = Easing.emphasizedAccelerate;

  /// How far a rising overlay travels, in logical pixels.
  static const riseDistance = 24.0;

  /// Fade in with a short rise; reversed on the way out. Translation and
  /// opacity only (no scaling or clipping), so text and layout hold still.
  static Widget riseTransition(Animation<double> animation, Widget child) {
    final curved = CurvedAnimation(parent: animation, curve: enterCurve, reverseCurve: exitCurve);
    return FadeTransition(
      opacity: curved,
      child: AnimatedBuilder(
        animation: curved,
        child: child,
        builder: (context, child) =>
            Transform.translate(offset: Offset(0, (1 - curved.value) * riseDistance), child: child),
      ),
    );
  }

  static bool reduceMotion(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  static bool get _haptics => !PlatformDetector.isTV() && (Platform.isAndroid || Platform.isIOS);

  /// Tab switches, chips, toggles, play/pause.
  /// Wraps a pull-to-refresh callback with a tick as the pull is let go
  /// past the threshold.
  static Future<void> Function() refreshing(Future<void> Function() onRefresh) => () {
    selection();
    return onRefresh();
  };

  static void selection() {
    if (_haptics) HapticFeedback.selectionClick();
  }

  /// A long press was recognised.
  static void longPress() {
    if (_haptics) HapticFeedback.mediumImpact();
  }

  /// Something was added or saved.
  static void success() {
    if (_haptics) HapticFeedback.lightImpact();
  }

  /// Something failed.
  static void error() {
    if (_haptics) HapticFeedback.heavyImpact();
  }
}
