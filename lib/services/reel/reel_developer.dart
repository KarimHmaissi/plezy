import 'package:flutter/foundation.dart';

import '../settings_service.dart';

/// The measure-day probes a `plezy://reel?probe=…` link names.
enum ReelProbeKind {
  /// Clip coverage over the For You pool (`probe=coverage`).
  coverage('coverage'),

  /// The shown card's watch state on the server (`probe=watchstate`).
  watchstate('watchstate'),

  /// The shape of the servers' extras: Media per extra, resolution,
  /// bitrate, codecs, channels (`probe=extras-shape`, plan V2-20).
  extrasShape('extras-shape');

  const ReelProbeKind(this.link);

  /// The name a `plezy://reel?probe=…` link gives it.
  final String link;
}

/// Fork: the Reel's hidden developer setting (plan V2-62). The debug
/// overlay with its `[ReelPerf]` ring (V2-07) and the measure-day links run
/// only in a debug build or with this setting on; in a release build a
/// `plezy://reel?probe=…` link from anywhere just opens the Reel.
///
/// The setting's row shows on the Reel settings page only in a debug build
/// or while debug logging (Settings, Advanced) is on, and it counts only
/// while its row could show: turning debug logging off turns the tools off
/// too, so nothing runs that can't be seen and switched off.
abstract final class ReelDeveloper {
  /// The prefs [on] reads, to listen to both.
  static const List<BoolPref> prefs = [SettingsService.reelDebugOverlay, SettingsService.enableDebugLogging];

  /// Whether the developer row shows on the Reel settings page.
  static bool visible({bool debugBuild = kDebugMode, SettingsService? settings}) {
    if (debugBuild) return true;
    return (settings ?? SettingsService.instanceOrNull)?.read(SettingsService.enableDebugLogging) ?? false;
  }

  /// Whether the tools are switched on: the overlay shows and the ring
  /// records.
  static bool on({bool debugBuild = kDebugMode, SettingsService? settings}) {
    final s = settings ?? SettingsService.instanceOrNull;
    if (s == null || !s.read(SettingsService.reelDebugOverlay)) return false;
    return visible(debugBuild: debugBuild, settings: s);
  }

  /// The probe a link named [name] may run, or null when the link should
  /// just open the Reel: no probe, an unknown one, or the tools are off in
  /// a release build.
  static ReelProbeKind? probe(String? name, {bool debugBuild = kDebugMode, SettingsService? settings}) {
    if (name == null) return null;
    final kind = ReelProbeKind.values.where((k) => k.link == name).firstOrNull;
    if (kind == null) return null;
    return debugBuild || on(debugBuild: debugBuild, settings: settings) ? kind : null;
  }
}
