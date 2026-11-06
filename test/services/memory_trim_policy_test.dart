import 'package:fake_async/fake_async.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/memory_trim_policy.dart';

/// Records the two wipes the policy must tell apart, and reports a settable
/// resident size so the watchdog floor can be crossed without decoding images.
class _RecordingImageCache extends ImageCache {
  int residentBytes = 64 << 20;
  int clears = 0;
  int liveClears = 0;

  @override
  int get currentSizeBytes => residentBytes;

  @override
  void clear() {
    clears++;
    super.clear();
  }

  @override
  void clearLiveImages() {
    liveClears++;
    super.clearLiveImages();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const imageTier = 128 << 20;
  const skiaTier = 400 << 20;

  late _RecordingImageCache cache;
  late List<int> skiaWrites;
  late int? skiaTierBytes;

  MemoryTrimPolicy newPolicy() => MemoryTrimPolicy(
    imageCache: () => cache,
    imageCacheTierBytes: () => imageTier,
    skiaCacheTierBytes: () => skiaTierBytes,
    setSkiaCacheBytes: skiaWrites.add,
  );

  setUp(() {
    cache = _RecordingImageCache()..maximumSizeBytes = imageTier;
    skiaWrites = [];
    skiaTierBytes = skiaTier;
  });

  group('memory pressure', () {
    test('halves the image cache budget and never empties it', () {
      fakeAsync((async) {
        final policy = newPolicy();
        policy.onMemoryPressure();
        expect(cache.maximumSizeBytes, imageTier ~/ 2);
        for (var i = 0; i < 20; i++) {
          policy.onMemoryPressure();
        }
        expect(cache.maximumSizeBytes, MemoryTrimPolicy.minImageCacheBytes);
        expect(cache.clears, 0);
        expect(cache.liveClears, 0);
        expect(skiaWrites, isEmpty, reason: 'pressure in the foreground leaves Skia alone');
        policy.dispose();
      });
    });

    test('restores the tier size after the cooldown in the foreground', () {
      fakeAsync((async) {
        final policy = newPolicy()..onMemoryPressure();
        async.elapse(MemoryTrimPolicy.restoreCooldown - const Duration(seconds: 1));
        expect(cache.maximumSizeBytes, imageTier ~/ 2);
        async.elapse(const Duration(seconds: 1));
        expect(cache.maximumSizeBytes, imageTier);
        policy.dispose();
      });
    });
  });

  group('RSS watchdog', () {
    test('halves first, clears only on the second consecutive over-threshold tick, never live images', () {
      fakeAsync((async) {
        final policy = newPolicy();
        expect(policy.onWatchdogTick(overThreshold: true), WatchdogTrim.halved);
        expect(cache.maximumSizeBytes, imageTier ~/ 2);
        expect(cache.clears, 0);

        expect(policy.onWatchdogTick(overThreshold: true), WatchdogTrim.cleared);
        expect(cache.clears, 1);

        // Under the threshold resets the run: the next spike halves again.
        expect(policy.onWatchdogTick(overThreshold: false), WatchdogTrim.none);
        expect(policy.onWatchdogTick(overThreshold: true), WatchdogTrim.halved);
        expect(cache.clears, 1);
        expect(cache.liveClears, 0);
        policy.dispose();
      });
    });

    test('restores to the tier size after the cooldown, not while RSS stays high', () {
      fakeAsync((async) {
        final policy = newPolicy();
        policy.onWatchdogTick(overThreshold: true);
        async.elapse(MemoryTrimPolicy.restoreCooldown);
        // The halving tick was the last sample: still over, so no restore yet.
        expect(cache.maximumSizeBytes, imageTier ~/ 2);

        policy.onWatchdogTick(overThreshold: false);
        async.elapse(MemoryTrimPolicy.restoreCooldown);
        expect(cache.maximumSizeBytes, imageTier);
        policy.dispose();
      });
    });

    test('signals a restore only once RSS has settled, for the Reel ladder', () {
      fakeAsync((async) {
        final policy = newPolicy();
        policy.onWatchdogTick(overThreshold: true);
        policy.onWatchdogTick(overThreshold: true);
        async.elapse(MemoryTrimPolicy.restoreCooldown * 2);
        expect(policy.restores.value, 0, reason: 'still over the threshold');

        policy.onWatchdogTick(overThreshold: false);
        async.elapse(MemoryTrimPolicy.restoreCooldown);
        expect(policy.restores.value, 1);
        policy.dispose();
      });
    });

    test('leaves an already small cache alone', () {
      fakeAsync((async) {
        final policy = newPolicy();
        cache.residentBytes = MemoryTrimPolicy.watchdogFloorBytes - 1;
        expect(policy.onWatchdogTick(overThreshold: true), WatchdogTrim.none);
        expect(policy.onWatchdogTick(overThreshold: true), WatchdogTrim.none);
        expect(cache.maximumSizeBytes, imageTier);
        expect(cache.clears, 0);
        policy.dispose();
      });
    });
  });

  group('trim levels', () {
    test('UI_HIDDEN halves the image cache and lowers Skia, once per hide', () {
      fakeAsync((async) {
        final policy = newPolicy()..onBackgrounded();
        policy.onTrimMemory(MemoryTrimPolicy.trimMemoryUiHidden);
        policy.onTrimMemory(MemoryTrimPolicy.trimMemoryUiHidden);
        expect(cache.maximumSizeBytes, imageTier ~/ 2);
        expect(skiaWrites, [skiaTier ~/ 2]);
        expect(cache.clears, 0);

        policy.onResumed();
        expect(cache.maximumSizeBytes, imageTier);
        expect(skiaWrites.last, skiaTier, reason: 'resume writes the tier size back, never a fixed value');
        policy.dispose();
      });
    });

    test('COMPLETE clears the keep-alive cache and floors both caches', () {
      fakeAsync((async) {
        final policy = newPolicy()..onBackgrounded();
        policy.onTrimMemory(MemoryTrimPolicy.trimMemoryComplete);
        expect(cache.clears, 1);
        expect(cache.liveClears, 0);
        expect(cache.maximumSizeBytes, MemoryTrimPolicy.minImageCacheBytes);
        expect(skiaWrites, [MemoryTrimPolicy.minSkiaCacheBytes]);
        policy.dispose();
      });
    });

    test('levels that reach the engine as memory pressure do nothing extra here', () {
      fakeAsync((async) {
        final policy = newPolicy();
        for (final level in [5, 10, 15, 40, 60]) {
          policy.onTrimMemory(level);
        }
        expect(cache.maximumSizeBytes, imageTier);
        expect(skiaWrites, isEmpty);
        policy.dispose();
      });
    });

    test('the channel handler maps onTrimMemory levels', () {
      fakeAsync((async) {
        final policy = newPolicy();
        policy.handleChannelCall(const MethodCall('onTrimMemory', MemoryTrimPolicy.trimMemoryUiHidden));
        async.flushMicrotasks();
        expect(cache.maximumSizeBytes, imageTier ~/ 2);
        expect(skiaWrites, [skiaTier ~/ 2]);
        Object? error;
        policy.handleChannelCall(const MethodCall('other')).catchError((Object e) => error = e);
        async.flushMicrotasks();
        expect(error, isA<MissingPluginException>());
        policy.dispose();
      });
    });

    test('Skia is left untouched where the engine has no Skia tier (Impeller, off Android)', () {
      fakeAsync((async) {
        skiaTierBytes = null;
        final policy = newPolicy()..onBackgrounded();
        policy.onTrimMemory(MemoryTrimPolicy.trimMemoryUiHidden);
        policy.onResumed();
        expect(skiaWrites, isEmpty);
        expect(cache.maximumSizeBytes, imageTier);
        policy.dispose();
      });
    });
  });

  group('background', () {
    test('steps down to the floors after 30 minutes and restores tier sizes on resume', () {
      fakeAsync((async) {
        final policy = newPolicy()..onBackgrounded();
        async.elapse(MemoryTrimPolicy.backgroundStepDownAfter - const Duration(minutes: 1));
        expect(cache.maximumSizeBytes, imageTier);
        expect(skiaWrites, isEmpty);

        async.elapse(const Duration(minutes: 1));
        expect(cache.maximumSizeBytes, MemoryTrimPolicy.minImageCacheBytes);
        expect(skiaWrites, [MemoryTrimPolicy.minSkiaCacheBytes]);
        expect(cache.clears, 0);

        policy.onResumed();
        expect(cache.maximumSizeBytes, imageTier);
        expect(skiaWrites.last, skiaTier);
        policy.dispose();
      });
    });

    test('a resume without a pause leaves a foreground trim to its cooldown', () {
      fakeAsync((async) {
        final policy = newPolicy()..onMemoryPressure();
        policy.onResumed();
        expect(cache.maximumSizeBytes, imageTier ~/ 2);
        async.elapse(MemoryTrimPolicy.restoreCooldown);
        expect(cache.maximumSizeBytes, imageTier);
        policy.dispose();
      });
    });

    test('a resume after a pause signals a restore', () {
      fakeAsync((async) {
        final policy = newPolicy()..onBackgrounded();
        policy.onMemoryPressure();
        async.elapse(MemoryTrimPolicy.restoreCooldown * 2);
        expect(policy.restores.value, 0, reason: 'the cooldown restore waits for resume');
        policy.onResumed();
        expect(policy.restores.value, 1);
        policy.dispose();
      });
    });

    test('a quick return cancels the step-down', () {
      fakeAsync((async) {
        final policy = newPolicy()..onBackgrounded();
        async.elapse(const Duration(minutes: 5));
        policy.onResumed();
        async.elapse(MemoryTrimPolicy.backgroundStepDownAfter);
        expect(cache.maximumSizeBytes, imageTier);
        expect(skiaWrites, isEmpty);
        policy.dispose();
      });
    });

    test('the cooldown restore waits for resume while backgrounded', () {
      fakeAsync((async) {
        final policy = newPolicy()..onBackgrounded();
        policy.onMemoryPressure();
        async.elapse(MemoryTrimPolicy.restoreCooldown * 3);
        expect(cache.maximumSizeBytes, imageTier ~/ 2);
        policy.onResumed();
        expect(cache.maximumSizeBytes, imageTier);
        policy.dispose();
      });
    });

    test('over the background RSS bar trims on pause, and UI_HIDDEN does not trim again', () {
      fakeAsync((async) {
        final policy = newPolicy()..onBackgrounded(rssOverBackgroundBar: true);
        expect(cache.maximumSizeBytes, imageTier ~/ 2);
        policy.onTrimMemory(MemoryTrimPolicy.trimMemoryUiHidden);
        expect(cache.maximumSizeBytes, imageTier ~/ 2);
        expect(skiaWrites, [skiaTier ~/ 2]);
        policy.dispose();
      });
    });
  });
}
