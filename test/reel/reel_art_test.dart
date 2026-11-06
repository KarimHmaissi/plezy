import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/device_performance.dart';
import 'package:plezy/services/memory_trim_policy.dart';
import 'package:plezy/services/reel/reel_art.dart';

/// A provider keyed by its name whose image is ready at once.
class _Art extends ImageProvider<_Art> {
  const _Art(this.name, this.image);

  final String name;
  final ImageInfo image;

  @override
  Future<_Art> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_Art key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(SynchronousFuture(image.clone()));

  @override
  bool operator ==(Object other) => other is _Art && other.name == name;

  @override
  int get hashCode => name.hashCode;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ImageInfo info;
  ImageCache cache() => PaintingBinding.instance.imageCache;

  /// Puts [art] in the image cache, as a precache or an earlier screen would.
  void decode(_Art art) =>
      cache().putIfAbsent(art, () => OneFrameImageStreamCompleter(SynchronousFuture(info.clone())));

  setUpAll(() async {
    info = ImageInfo(image: await createTestImage(width: 4, height: 4));
  });

  setUp(() {
    ReelArt.resetForTesting();
    cache().clear();
    cache().clearLiveImages();
  });

  tearDownAll(() => info.dispose());

  test("suspending evicts the art the Reel decoded and nothing else", () {
    final home = _Art('home-backdrop', info);
    final card = _Art('harbor-lights-thumb', info);
    decode(home);

    // Tracking learns the art's size from its decode (here at once).
    ReelArt.track(card);
    expect(cache().containsKey(card), isTrue);

    expect(ReelArt.evict(), 1);
    expect(cache().containsKey(card), isFalse);
    expect(cache().containsKey(home), isTrue, reason: "Home's art was never the Reel's");
    expect(ReelArt.trackedCount, 0);
  });

  test("art already cached when the Reel first asks is someone else's", () {
    // Home's spotlight showed the same title at the same size.
    final shared = _Art('shared-backdrop', info);
    decode(shared);

    ReelArt.track(shared);
    expect(ReelArt.evict(), 0);
    expect(cache().containsKey(shared), isTrue);
  });

  test('a build after the Reel decoded it still counts as the Reel\'s own', () {
    final card = _Art('quiet-meadow-thumb', info);
    ReelArt.track(card);
    decode(card);
    // The card rebuilds: its art is cached now, but by the Reel.
    ReelArt.track(card);
    expect(ReelArt.evict(), 1);
  });

  test('art still on screen keeps its image and stays tracked for the next suspend', () async {
    final card = _Art('night-ferry-thumb', info);
    ReelArt.track(card);
    // The mounted card's Image listens while the art loads, as it does for
    // server art.
    final loaded = Completer<ImageInfo>();
    final stream = cache().putIfAbsent(card, () => OneFrameImageStreamCompleter(loaded.future))!;
    void onImage(ImageInfo image, bool _) => image.dispose();
    final listener = ImageStreamListener(onImage);
    stream.addListener(listener);
    loaded.complete(info.clone());
    await Future<void>.delayed(Duration.zero);
    expect(cache().statusForKey(card).keepAlive, isTrue);
    expect(cache().statusForKey(card).live, isTrue);

    expect(ReelArt.evict(), 1);
    expect(cache().statusForKey(card).live, isTrue, reason: 'the mounted card keeps painting');
    expect(ReelArt.trackedCount, 1);

    // The card's next build finds it live, and it is still the Reel's.
    ReelArt.track(card);
    stream.removeListener(listener);
    expect(cache().statusForKey(card).live, isFalse);
    expect(ReelArt.trackedCount, 1);
    ReelArt.evict();
    expect(ReelArt.trackedCount, 0);
  });

  group('the budget while the Reel is active (plan §6)', () {
    // Each test image is 4x4 RGBA: 64 bytes.
    const each = 64;

    /// A mounted widget painting [provider], until the returned callback.
    VoidCallback paint(ImageProvider provider) {
      void onImage(ImageInfo image, bool _) => image.dispose();
      final listener = ImageStreamListener(onImage);
      final stream = provider.resolve(ImageConfiguration.empty)..addListener(listener);
      return () => stream.removeListener(listener);
    }

    /// Tracks [name] as [card]'s art; it decodes at once.
    _Art art(String name, {String? card}) {
      final a = _Art(name, info);
      ReelArt.track(a, card: card);
      return a;
    }

    test('holds nothing back while suspended; keep turns it on and trims at once', () {
      ReelArt.debugBudgetBytes = () => 2 * each;
      final old = [for (var i = 0; i < 4; i++) art('harbor-lights-$i', card: 'c$i')];
      expect(ReelArt.heldBytes, 4 * each, reason: 'no window yet: no budget');

      ReelArt.keep(['c3', 'c2']);
      expect(ReelArt.heldBytes, 2 * each);
      expect(cache().containsKey(old[0]), isFalse, reason: 'the oldest card outside the window goes first');
      expect(cache().containsKey(old[1]), isFalse);
      expect(cache().containsKey(old[2]), isTrue);
      expect(cache().containsKey(old[3]), isTrue);
    });

    test('each decode over the budget trims the cards that left the window, oldest first', () {
      ReelArt.debugBudgetBytes = () => 3 * each;
      ReelArt.keep(['c2', 'c3']);
      final behind = art('quiet-meadow', card: 'c0');
      final logo = art('remote-tile');
      final shown = art('night-ferry', card: 'c2');
      final ahead = art('night-ferry-next', card: 'c3');
      expect(ReelArt.heldBytes, 3 * each);
      expect(cache().containsKey(behind), isFalse);
      expect(cache().containsKey(logo), isTrue, reason: 'within the budget once the oldest went');

      art('night-ferry-later', card: 'c3');
      expect(cache().containsKey(logo), isFalse, reason: 'art with no card goes before the window');
      expect(cache().containsKey(shown), isTrue);
      expect(cache().containsKey(ahead), isTrue);
    });

    test("then the window's farthest card; never what the card on screen shows", () {
      ReelArt.debugBudgetBytes = () => 2 * each;
      // Nearest first: on screen, +1, -1, +2.
      ReelArt.keep(['c1', 'c2', 'c0', 'c3']);
      final shown = art('harbor-lights', card: 'c1');
      addTearDown(paint(shown));
      final next = art('quiet-meadow', card: 'c2');
      final before = art('night-ferry', card: 'c0');
      final last = art('salt-road', card: 'c3');
      expect(cache().containsKey(last), isFalse, reason: '+2 is the farthest');
      expect(cache().containsKey(before), isFalse, reason: 'then -1');
      expect(cache().containsKey(next), isTrue);
      expect(cache().containsKey(shown), isTrue);

      ReelArt.debugBudgetBytes = () => 0;
      ReelArt.trim();
      expect(cache().containsKey(next), isFalse);
      expect(cache().containsKey(shown), isTrue, reason: 'the card on screen is the floor');
    });

    test('the card on screen keeps what it shows but not a size it was laid out at before', () async {
      ReelArt.debugBudgetBytes = () => each;
      ReelArt.keep(['c1']);
      final before = art('harbor-lights-small', card: 'c1');
      final showing = art('harbor-lights-large', card: 'c1');
      // The page paints the new size.
      addTearDown(paint(showing));
      ReelArt.trim();
      expect(cache().containsKey(before), isFalse);
      expect(cache().containsKey(showing), isTrue);
    });

    test('art still on screen outside the window keeps painting; only the cache copy goes', () async {
      ReelArt.debugBudgetBytes = () => 0;
      final card = _Art('salt-road', info);
      ReelArt.track(card, card: 'c0');
      addTearDown(paint(card));
      ReelArt.keep(['c5']);
      expect(cache().statusForKey(card).keepAlive, isFalse);
      expect(cache().statusForKey(card).live, isTrue, reason: 'the page sliding away still paints it');
      expect(ReelArt.trackedCount, 1, reason: 'still the Reel\'s on its next build');
    });

    test("never someone else's art", () {
      ReelArt.debugBudgetBytes = () => 0;
      final home = _Art('home-backdrop', info);
      decode(home);
      ReelArt.track(home, card: 'c0');
      ReelArt.keep(['c9']);
      expect(cache().containsKey(home), isTrue);
    });

    test('art still loading counts once it has decoded, and the decode trims', () async {
      ReelArt.debugBudgetBytes = () => each;
      ReelArt.keep(['c1']);
      final shown = art('harbor-lights', card: 'c1');
      final loaded = Completer<ImageInfo>();
      final late = _LateArt('quiet-meadow', loaded.future);
      ReelArt.track(late, card: 'c0');
      expect(ReelArt.heldBytes, each);
      loaded.complete(info.clone());
      await Future<void>.delayed(Duration.zero);
      expect(cache().containsKey(late), isFalse, reason: 'it left the window before it arrived');
      expect(cache().containsKey(shown), isTrue);
    });

    test('suspend turns the budget off', () {
      ReelArt.debugBudgetBytes = () => 0;
      ReelArt.keep(['c1']);
      ReelArt.evict();
      final later = art('night-ferry', card: 'c0');
      expect(cache().containsKey(later), isTrue, reason: 'nothing trims until the next keep');
    });

    test("the budget is the device's share, scaled by the app's memory trim", () {
      final policy = MemoryTrimPolicy(
        imageCache: cache,
        imageCacheTierBytes: () => 100 << 20,
        skiaCacheTierBytes: () => null,
        setSkiaCacheBytes: (_) {},
      );
      MemoryTrimPolicy.debugInstance = policy;
      addTearDown(() => MemoryTrimPolicy.debugInstance = null);
      final tierMax = cache().maximumSizeBytes;
      addTearDown(() => cache().maximumSizeBytes = tierMax);
      cache().maximumSizeBytes = 100 << 20;
      final full = ReelArt.budgetBytes();
      expect(full, DevicePerformance.reelImageBudgetBytes());

      policy.halveImageCache('test');
      expect(ReelArt.budgetBytes(), full ~/ 2);
      policy.restoreTierSizes('test');
      expect(ReelArt.budgetBytes(), full);
    });
  });

  test('nothing tracked leaves the cache alone', () {
    final home = _Art('home-backdrop', info);
    decode(home);
    expect(ReelArt.evict(), 0);
    expect(cache().containsKey(home), isTrue);
  });
}

/// A provider keyed by its name whose image arrives when [image] completes.
class _LateArt extends ImageProvider<_LateArt> {
  const _LateArt(this.name, this.image);

  final String name;
  final Future<ImageInfo> image;

  @override
  Future<_LateArt> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_LateArt key, ImageDecoderCallback decode) => OneFrameImageStreamCompleter(image);

  @override
  bool operator ==(Object other) => other is _LateArt && other.name == name;

  @override
  int get hashCode => name.hashCode;
}
