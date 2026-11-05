import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../services/memory_trim_policy.dart';
import '../services/playback_coordinator.dart';
import 'app_logger.dart';

/// Records what the process held when the OS asked it to release memory.
///
/// The native SDKs log each warning as a bare `device.event` "Low memory"
/// breadcrumb, so the iOS watchdog terminations and Android low-memory exits
/// that follow (#445) say nothing about what was resident. This adds one
/// `memory.pressure` breadcrumb with process RSS, the image cache and the video
/// session as they stood when the warning arrived.
///
/// It wraps the whole dispatch because the framework's own handler runs first:
/// [PaintingBinding.handleMemoryPressure] empties the keep-alive image cache
/// before any `WidgetsBindingObserver.didHaveMemoryPressure` is called. That
/// wipe is held off here: the rest of the dispatch (the asset bundle cache,
/// every observer) still runs, and [MemoryTrimPolicy.onMemoryPressure] halves
/// the cache's budget instead, so artwork Plezy will show again on a warm
/// return survives. The `…After` numbers are sampled once every observer and
/// the halving have run.
///
/// iOS delivers warnings in bursts (15 within 1.2 seconds in one #445 report),
/// so at most one breadcrumb is recorded per [breadcrumbInterval]; the next one
/// counts the warnings folded into it as `suppressed`. Every value read here is
/// an in-process counter or cached player state, never a platform-channel
/// round trip.
mixin MemoryPressureBreadcrumbs on PaintingBinding {
  static const breadcrumbInterval = Duration(seconds: 30);

  DateTime? _lastMemoryPressureBreadcrumb;
  int _suppressedMemoryPressureSignals = 0;

  @override
  ImageCache createImageCache() => _TrimmingImageCache();

  void _holdImageCacheClear(bool hold) {
    final cache = imageCache;
    if (cache is _TrimmingImageCache) cache._holdClear = hold;
  }

  @override
  void handleMemoryPressure() {
    final now = clock.now();
    final last = _lastMemoryPressureBreadcrumb;
    // A wall clock set backwards must not silence the breadcrumb until it
    // catches up again.
    final throttled = last != null && !now.isBefore(last) && now.difference(last) < breadcrumbInterval;
    final cache = imageCache;
    Map<String, Object>? data;
    if (throttled) {
      _suppressedMemoryPressureSignals++;
    } else {
      _lastMemoryPressureBreadcrumb = now;
      data = <String, Object>{
        ...?_megabytes('rssMb', () => ProcessInfo.currentRss),
        ...?_megabytes('maxRssMb', () => ProcessInfo.maxRss),
        'imageCacheMb': cache.currentSizeBytes >> 20,
        'imageCacheImages': cache.currentSize,
        'liveImages': cache.liveImageCount,
        ..._playbackData(),
      };
    }

    // The framework's handler and the observers, with their image-cache wipe
    // held off; then the policy halves the budget instead.
    _holdImageCacheClear(true);
    try {
      super.handleMemoryPressure();
    } finally {
      _holdImageCacheClear(false);
    }
    MemoryTrimPolicy.instance.onMemoryPressure();
    if (data == null) return;

    data
      ..['imageCacheMbAfter'] = cache.currentSizeBytes >> 20
      ..['imageCacheImagesAfter'] = cache.currentSize
      ..['liveImagesAfter'] = cache.liveImageCount;
    if (_suppressedMemoryPressureSignals > 0) data['suppressed'] = _suppressedMemoryPressureSignals;
    _suppressedMemoryPressureSignals = 0;

    unawaited(
      Sentry.addBreadcrumb(
        Breadcrumb(message: 'Memory pressure', category: 'memory.pressure', level: SentryLevel.warning, data: data),
      ),
    );
    appLogger.i('Memory pressure: ${data.entries.map((e) => '${e.key}=${e.value}').join(' ')}');
  }

  @visibleForTesting
  void debugResetMemoryPressureBreadcrumbs() {
    _lastMemoryPressureBreadcrumb = null;
    _suppressedMemoryPressureSignals = 0;
  }

  /// RSS reads are syscalls that can fail; a failed read drops its key rather
  /// than the platform's memory-pressure handling behind it.
  static Map<String, Object>? _megabytes(String key, int Function() readBytes) {
    try {
      return {key: readBytes() >> 20};
    } catch (_) {
      return null;
    }
  }

  static Map<String, Object> _playbackData() {
    final playback = PlaybackCoordinator.instance;
    final player = playback.videoPlayerState;
    return {
      'videoSession': playback.hasVideoSession,
      if (player != null) ...{
        'playbackActive': player.isActive,
        'bufferAheadMs': math.max(0, (player.buffer - player.position).inMilliseconds),
      },
    };
  }
}

/// The app's image cache. [clear] is ignored only during the memory-pressure
/// dispatch ([MemoryPressureBreadcrumbs]), whose framework handler and
/// observers would otherwise empty it; every other caller, the watchdog's last
/// resort included, clears as usual.
class _TrimmingImageCache extends ImageCache {
  bool _holdClear = false;

  @override
  void clear() {
    if (_holdClear) return;
    super.clear();
  }
}
