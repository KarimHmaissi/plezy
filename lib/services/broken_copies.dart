import 'package:flutter/foundation.dart';

import '../media/copy_fallback.dart';
import '../media/media_item.dart';
import '../media/media_version.dart';
import '../utils/app_logger.dart';
import 'settings_service.dart';

/// Fork: files that failed to open recently, so Play's default and the copy
/// fallback go to one that works.
///
/// Keyed by [copySourceKey] (server, item id, version id; no token, address
/// or name). A failure is remembered for the rest of the app run, and on this
/// device for [ttl] after it ([SettingsService.brokenCopies]). A file that
/// later plays is forgotten at once.
class BrokenCopies {
  BrokenCopies._();

  static final BrokenCopies instance = BrokenCopies._();

  /// How long a failure outlives the app run that saw it.
  static const Duration ttl = Duration(hours: 24);

  /// Most failures kept on disk; the oldest go first.
  static const int maxEntries = 200;

  final Set<String> _thisRun = {};
  Map<String, int> _stored = {};
  bool _loaded = false;
  DateTime Function() _now = DateTime.now;

  /// Reads the stored failures once per app run. Callers that decide a
  /// default await it; it never throws. No future is kept between calls (two
  /// early callers both read, harmlessly), so a caller never waits on a read
  /// another isolate zone started and abandoned.
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    await _load();
  }

  Future<void> _load() async {
    try {
      final settings = await SettingsService.getInstance();
      final stored = settings.read(SettingsService.brokenCopies);
      _stored = {
        for (final entry in stored.entries)
          if (_fresh(entry.value)) entry.key: entry.value,
        // A failure recorded while the read was in flight wins.
        ..._stored,
      };
      _loaded = true;
    } catch (e) {
      appLogger.w('Could not read the copies that failed to play', error: e);
    }
  }

  bool _fresh(int? failedAtMs) => failedAtMs != null && _now().millisecondsSinceEpoch - failedAtMs < ttl.inMilliseconds;

  /// Whether the file under [key] failed in this run or within [ttl].
  bool isBroken(String key) => _thisRun.contains(key) || _fresh(_stored[key]);

  /// Whether [version] of [copy] failed recently.
  bool isVersionBroken(MediaItem copy, MediaVersion? version) => isBroken(copySourceKey(copy, version));

  /// Whether every version of [copy] failed recently (the copy itself when
  /// its versions are unknown).
  bool isCopyBroken(MediaItem copy) {
    final versions = copy.mediaVersions ?? const <MediaVersion>[];
    if (versions.isEmpty) return isBroken(copySourceKey(copy, null));
    return versions.every((version) => isVersionBroken(copy, version));
  }

  /// Remember that the file under [key] failed to open.
  Future<void> markBroken(String key) async {
    _thisRun.add(key);
    await ensureLoaded();
    _stored[key] = _now().millisecondsSinceEpoch;
    await _write();
  }

  /// The file under [key] played: forget any failure of it.
  Future<void> clear(String key) async {
    final wasInRun = _thisRun.remove(key);
    await ensureLoaded();
    final wasStored = _stored.remove(key) != null;
    if (wasStored) await _write();
    if (wasInRun || wasStored) appLogger.i('[CopyFallback] a copy that failed before has played; forgotten');
  }

  Future<void> _write() async {
    try {
      final settings = await SettingsService.getInstance();
      final kept = _stored.entries.where((entry) => _fresh(entry.value)).toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      _stored = Map.fromEntries(kept.take(maxEntries));
      await settings.write(SettingsService.brokenCopies, _stored);
    } catch (e) {
      appLogger.w('Could not store the copies that failed to play', error: e);
    }
  }

  @visibleForTesting
  void resetForTesting({DateTime Function()? now}) {
    _thisRun.clear();
    _stored = {};
    _loaded = false;
    _now = now ?? DateTime.now;
  }

  /// Forget this run's failures, as an app restart does, keeping the stored
  /// ones.
  @visibleForTesting
  void restartForTesting() {
    _thisRun.clear();
    _stored = {};
    _loaded = false;
  }
}
