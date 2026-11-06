import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/screens/reel/reel_feed_view.dart';
import 'package:plezy/services/reel/reel_art.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/utils/media_image_helper.dart';
import 'package:plezy/widgets/optimized_media_image.dart';
import 'package:plezy/widgets/tv_spotlight_background.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/prefs.dart';

/// Sized transcode URLs; nothing else is asked of it.
class _Client implements MediaServerClient {
  @override
  String thumbnailUrl(String? path, {int? width, int? height, bool cover = true}) =>
      'https://server-a.example$path?w=$width&h=$height&cover=$cover';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The Reel warms the next cards' art (plan V2-13) with the providers the
/// card views build, so the warm entry is the one they read. These pin that
/// the two never drift: a mismatch is a full-size decode nobody shows.
void main() {
  late ImageInfo info;
  final client = _Client();
  final item = testMediaItem(
    id: 'harbor-lights',
    kind: MediaKind.movie,
    title: 'Harbor Lights',
    artPath: '/library/metadata/7/art/1',
    thumbPath: '/library/metadata/7/thumb/1',
  );

  ImageCache cache() => PaintingBinding.instance.imageCache;

  Future<Object> keyOf(ImageProvider provider) => provider.obtainKey(ImageConfiguration.empty);

  /// Decodes [provider] into the cache, as the warm does, without a network.
  Future<Object> warm(ImageProvider provider) async {
    final key = await keyOf(provider);
    cache().putIfAbsent(key, () => OneFrameImageStreamCompleter(SynchronousFuture(info.clone())));
    return key;
  }

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    info = ImageInfo(image: await createTestImage(width: 4, height: 4));
  });

  setUp(() {
    ReelArt.resetForTesting();
    cache().clear();
    cache().clearLiveImages();
  });

  tearDownAll(() => info.dispose());

  group('TV spotlight', () {
    for (final (name, light, decode) in [
      ('a clip card warms the thumbnail art it shows under the clip', true, (960, 540)),
      ('an AI card warms the full backdrop', false, (1920, 1080)),
    ]) {
      testWidgets(name, (tester) async {
        resetSharedPreferencesForTest();
        await tester.runAsync(SettingsService.getInstance);
        tester.view.physicalSize = const Size(1920, 1080);
        tester.view.devicePixelRatio = 1;
        tester.view.display.size = const Size(1920, 1080);
        addTearDown(tester.view.reset);
        addTearDown(tester.view.display.reset);

        ImageProvider? warmed;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) {
                warmed = TvSpotlightBackground.artProviderFor(context, item, client, lightArt: light);
                return const SizedBox.shrink();
              },
            ),
          ),
        );
        expect(warmed, isA<ResizeImage>());
        final resized = warmed! as ResizeImage;
        expect((resized.width, resized.height), decode);
        final key = await warm(warmed!);

        final built = <ImageProvider>[];
        await tester.pumpWidget(
          MaterialApp(
            home: TvSpotlightBackground(
              item: item,
              client: client,
              showInfo: false,
              lightArt: light,
              onArtProvider: built.add,
            ),
          ),
        );
        await tester.pump();
        expect(built, isNotEmpty);
        expect(await keyOf(built.first), key, reason: 'the card reads the entry the warm decoded');
        expect(cache().statusForKey(key).live, isTrue);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  });

  group('phone feed', () {
    test("the still's frame: as wide as the page, or as tall as it when that is too tall", () {
      expect(reelStillFrame(const Size(400, 800), 16 / 9), const Size(400, 225));
      final tall = reelStillFrame(const Size(800, 300), 16 / 9);
      expect(tall.width, moreOrLessEquals(300 * 16 / 9));
      expect(tall.height, 300);
    });

    for (final (name, slot, explicit) in [
      ('the still warms at its frame in the page', reelStillFrame(const Size(400, 800), 16 / 9), false),
      ('the ambient backdrop warms at its tiny slot', const Size(36, 64), true),
    ]) {
      testWidgets(name, (tester) async {
        tester.view.physicalSize = const Size(400, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        ImageProvider? warmed;
        final built = <ImageProvider>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) {
                warmed = MediaImageHelper.serverArtworkProviderFor(
                  context,
                  client: client,
                  thumbPath: item.artPath,
                  width: slot.width,
                  height: slot.height,
                  imageType: ImageType.art,
                )?.provider;
                return const SizedBox.shrink();
              },
            ),
          ),
        );
        expect(warmed, isNotNull);
        final key = await warm(warmed!);

        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: SizedBox(
                width: slot.width,
                height: slot.height,
                child: OptimizedMediaImage(
                  client: client,
                  imagePath: item.artPath,
                  width: explicit ? slot.width : null,
                  height: explicit ? slot.height : null,
                  fit: BoxFit.cover,
                  imageType: ImageType.art,
                  onImageProvider: built.add,
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(built, isNotEmpty);
        expect(await keyOf(built.first), key, reason: 'the page reads the entry the warm decoded');
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  });

  testWidgets('a warm is tracked, so suspend evicts it with the rest of the Reel\'s art', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      Builder(
        builder: (context) {
          ctx = context;
          return const SizedBox.shrink();
        },
      ),
    );
    final provider = _Art('harbor-lights-thumb', info);
    await ReelArt.precache(provider, ctx);
    expect(ReelArt.trackedCount, 1);
    expect(cache().containsKey(await keyOf(provider)), isTrue);
    expect(ReelArt.evict(), 1);
    expect(cache().containsKey(await keyOf(provider)), isFalse);
  });
}

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
