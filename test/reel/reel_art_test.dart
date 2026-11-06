import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
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

    ReelArt.track(card);
    decode(card);
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

  test('nothing tracked leaves the cache alone', () {
    final home = _Art('home-backdrop', info);
    decode(home);
    expect(ReelArt.evict(), 0);
    expect(cache().containsKey(home), isTrue);
  });
}
