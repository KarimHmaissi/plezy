import 'package:flutter/foundation.dart';

/// The Reel's own loudness on the TV (V2-49): On TV mode's volume buttons
/// move it in steps of [step]. It is a ceiling on every level the clip core
/// is sent ([scale]), so the fades between cards keep their shape at any
/// volume, and like the main player's remote volume it never touches the
/// system's. It lasts for the app's run.
abstract final class ReelVolume {
  static const int step = 10;
  static const int max = 100;

  /// 0–[max], [max] by default.
  static final ValueNotifier<int> level = ValueNotifier(max);

  /// One press of the remote's volume up (+1) or down (-1).
  static void adjust(int dir) => level.value = (level.value + dir.sign * step).clamp(0, max);

  /// What the core is sent for a requested 0–100 [volume] at [level].
  static double scale(double volume, int level) => volume * level.clamp(0, max) / max;

  @visibleForTesting
  static void reset() => level.value = max;
}
