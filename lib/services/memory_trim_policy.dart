import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

import '../utils/app_logger.dart';
import 'device_performance.dart';

/// What one RSS watchdog tick did to the image cache.
enum WatchdogTrim { none, halved, cleared }

/// How Plezy gives memory back, and how it takes it back: trim, never wipe.
///
/// Back on Android TV now leaves Plezy running behind the launcher, so every
/// release here has to keep the process cheap enough that the low-memory
/// killer passes it over, and has to keep what is on screen intact for the warm
/// return. Every step therefore halves a budget (ImageCache evicts its least
/// recently used entries down to the new bound) instead of emptying it:
///
/// * memory pressure from the OS ([onMemoryPressure]) halves the image cache;
/// * the UI going out of sight (`TRIM_MEMORY_UI_HIDDEN`, or an over-the-bar
///   RSS on pause) halves the image cache and the Skia resource cache, once;
/// * the RSS watchdog halves on its first over-threshold tick, and only a
///   second consecutive one clears the keep-alive cache. `TRIM_MEMORY_COMPLETE`
///   clears it too. Nothing here ever calls [ImageCache.clearLiveImages], which
///   would blank artwork still on screen;
/// * after [backgroundStepDownAfter] in the background both caches drop to
///   their floors, handing the memory to whatever the family is watching.
///
/// Budgets come back to the device tier's sizes ([DevicePerformance]) on
/// resume, and in the foreground [restoreCooldown] after the last trim once
/// the watchdog no longer sees RSS over its threshold. Time is read only
/// through [Timer]s, so `fake_async` drives every schedule in tests.
class MemoryTrimPolicy {
  MemoryTrimPolicy({
    required this._imageCache,
    required this._imageCacheTierBytes,
    required this._skiaCacheTierBytes,
    required this._setSkiaCacheBytes,
  });

  /// The app's caches and this device's tier sizes.
  factory MemoryTrimPolicy.platform() => MemoryTrimPolicy(
    imageCache: () => PaintingBinding.instance.imageCache,
    imageCacheTierBytes: DevicePerformance.imageCacheTierBytes,
    skiaCacheTierBytes: DevicePerformance.skiaResourceCacheTierBytes,
    setSkiaCacheBytes: (bytes) =>
        SystemChannels.skia.invokeMethod<void>('Skia.setResourceCacheMaxBytes', bytes).catchError((_) {}).ignore(),
  );

  static MemoryTrimPolicy? _instance;

  static MemoryTrimPolicy get instance => _instance ??= MemoryTrimPolicy.platform();

  @visibleForTesting
  static set debugInstance(MemoryTrimPolicy? value) {
    _instance?.dispose();
    _instance = value;
  }

  /// PlezyActivity forwards every `onTrimMemory` level here.
  static const channel = MethodChannel('com.plezy/memory_trim');

  /// `ComponentCallbacks2` levels this policy acts on itself. The others reach
  /// it through the engine's memory-pressure message ([onMemoryPressure]).
  static const trimMemoryUiHidden = 20;
  static const trimMemoryComplete = 80;

  static const minImageCacheBytes = 8 << 20;
  static const minSkiaCacheBytes = 16 << 20;

  /// Below this the watchdog leaves the cache alone: trimming an already
  /// small cache buys nothing, and refetch churn is its own spike source.
  static const watchdogFloorBytes = 8 << 20;

  static const restoreCooldown = Duration(seconds: 60);
  static const backgroundStepDownAfter = Duration(minutes: 30);

  static const _tag = '[MemoryTrim]';

  final ImageCache Function() _imageCache;
  final int Function() _imageCacheTierBytes;
  final int? Function() _skiaCacheTierBytes;
  final void Function(int bytes) _setSkiaCacheBytes;

  bool _foreground = true;
  bool _hiddenTrimApplied = false;
  bool _skiaLowered = false;
  int _overThresholdTicks = 0;
  Timer? _restoreTimer;
  Timer? _stepDownTimer;
  final ValueNotifier<int> _restores = ValueNotifier(0);

  /// Ticks each time both caches go back to the tier sizes (resume, or a
  /// settled cooldown): the all-clear the Reel's degrade ladder waits for.
  ValueListenable<int> get restores => _restores;

  /// Listens for PlezyActivity's trim levels. Only Android sends them.
  void attachChannel() => channel.setMethodCallHandler(handleChannelCall);

  @visibleForTesting
  Future<Object?> handleChannelCall(MethodCall call) async {
    if (call.method != 'onTrimMemory') throw MissingPluginException('${call.method} is not a memory trim method');
    final level = call.arguments;
    if (level is int) onTrimMemory(level);
    return null;
  }

  /// The framework's memory-pressure signal, in place of its own
  /// `imageCache.clear()` (see MemoryPressureBreadcrumbs).
  void onMemoryPressure() => halveImageCache('memory pressure');

  /// One `onTrimMemory` level from PlezyActivity.
  void onTrimMemory(int level) {
    if (level >= trimMemoryComplete) {
      // Next in line for the low-memory killer: the last resort, which still
      // keeps live (on-screen) images.
      _imageCache().clear();
      _stepDownToMinimum('trim complete');
    } else if (level == trimMemoryUiHidden) {
      _applyHiddenTrim('ui hidden');
    }
    // BACKGROUND, MODERATE and the RUNNING_* levels also reach the engine,
    // which turns them into memory pressure: [onMemoryPressure] halves.
  }

  /// Halves the image cache's byte budget, never below [minImageCacheBytes].
  void halveImageCache(String reason) {
    final cache = _imageCache();
    final before = cache.maximumSizeBytes;
    final after = math.max(minImageCacheBytes, before ~/ 2);
    _markTrimmed();
    if (after >= before) return;
    cache.maximumSizeBytes = after;
    appLogger.i('$_tag $reason: image cache budget ${before >> 20}MB -> ${after >> 20}MB');
  }

  /// [bytes] of the image cache that one surface keeps for itself (the
  /// Reel's art, plan §6), scaled by how far a trim has the cache below its
  /// tier now: the share halves with every halving and comes back with the
  /// restore, so it never outlives the trim's cause either.
  int scaledShare(int bytes) {
    final tier = _imageCacheTierBytes();
    final now = _imageCache().maximumSizeBytes;
    if (tier <= 0 || now >= tier) return bytes;
    return (bytes * now) ~/ tier;
  }

  /// One RSS watchdog sample.
  WatchdogTrim onWatchdogTick({required bool overThreshold}) {
    if (!overThreshold) {
      _overThresholdTicks = 0;
      return WatchdogTrim.none;
    }
    final secondTick = _overThresholdTicks > 0;
    _overThresholdTicks++;
    final cache = _imageCache();
    if (cache.currentSizeBytes < watchdogFloorBytes) return WatchdogTrim.none;
    if (!secondTick) {
      halveImageCache('rss watchdog');
      return WatchdogTrim.halved;
    }
    // Still over after halving: drop cached and pending images that are not
    // on screen.
    cache.clear();
    _markTrimmed();
    appLogger.w('$_tag rss watchdog: still over threshold, cleared the keep-alive image cache');
    return WatchdogTrim.cleared;
  }

  /// The app left the foreground. [rssOverBackgroundBar] applies the hidden
  /// trim now rather than waiting on a best-effort `TRIM_MEMORY_UI_HIDDEN`.
  void onBackgrounded({bool rssOverBackgroundBar = false}) {
    _foreground = false;
    _restoreTimer?.cancel();
    _restoreTimer = null;
    if (rssOverBackgroundBar) _applyHiddenTrim('background over rss bar');
    _stepDownTimer?.cancel();
    _stepDownTimer = Timer(backgroundStepDownAfter, () => _stepDownToMinimum('background step-down'));
  }

  /// Back in the foreground after [onBackgrounded]. A resume that never
  /// followed a pause (a system dialog closing) leaves a foreground trim to
  /// its cooldown.
  void onResumed() {
    if (_foreground) return;
    _foreground = true;
    _stepDownTimer?.cancel();
    _stepDownTimer = null;
    _hiddenTrimApplied = false;
    _overThresholdTicks = 0;
    restoreTierSizes('resume');
  }

  /// Puts both caches back to the device tier's sizes.
  void restoreTierSizes(String reason) {
    _restoreTimer?.cancel();
    _restoreTimer = null;
    final cache = _imageCache();
    final tier = _imageCacheTierBytes();
    final restoredImage = cache.maximumSizeBytes != tier;
    if (restoredImage) cache.maximumSizeBytes = tier;
    var restoredSkia = false;
    if (_skiaLowered) {
      final skiaTier = _skiaCacheTierBytes();
      if (skiaTier != null) {
        _setSkiaCacheBytes(skiaTier);
        restoredSkia = true;
      }
      _skiaLowered = false;
    }
    if (restoredImage || restoredSkia) {
      appLogger.i('$_tag $reason: restored tier sizes (image ${tier >> 20}MB${restoredSkia ? ', skia' : ''})');
    }
    _restores.value++;
  }

  void dispose() {
    _restoreTimer?.cancel();
    _stepDownTimer?.cancel();
  }

  void _applyHiddenTrim(String reason) {
    if (_hiddenTrimApplied) return;
    _hiddenTrimApplied = true;
    halveImageCache(reason);
    final skiaTier = _skiaCacheTierBytes();
    if (skiaTier != null) _lowerSkia(math.max(minSkiaCacheBytes, skiaTier ~/ 2), reason);
  }

  void _stepDownToMinimum(String reason) {
    final cache = _imageCache();
    if (cache.maximumSizeBytes > minImageCacheBytes) cache.maximumSizeBytes = minImageCacheBytes;
    if (_skiaCacheTierBytes() != null) _lowerSkia(minSkiaCacheBytes, reason);
    _markTrimmed();
    appLogger.i('$_tag $reason: image cache at its floor');
  }

  void _lowerSkia(int bytes, String reason) {
    _setSkiaCacheBytes(bytes);
    _skiaLowered = true;
    appLogger.i('$_tag $reason: skia resource cache ${bytes >> 20}MB');
  }

  /// Re-arms the foreground restore for [restoreCooldown] after this trim.
  /// In the background it waits for [onResumed] instead.
  void _markTrimmed() {
    _restoreTimer?.cancel();
    _restoreTimer = _foreground ? Timer(restoreCooldown, _restoreIfSettled) : null;
  }

  void _restoreIfSettled() {
    _restoreTimer = null;
    if (!_foreground) return;
    // RSS still over the watchdog threshold: try again after another cooldown.
    if (_overThresholdTicks > 0) {
      _restoreTimer = Timer(restoreCooldown, _restoreIfSettled);
      return;
    }
    restoreTierSizes('cooldown');
  }
}
