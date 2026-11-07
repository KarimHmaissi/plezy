import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/reel/reel_clip_cache.dart';

/// V2-10: the Dart side of the clip core's disk cache.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test/reel_clip_cache');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;

  void answer(Object? Function(MethodCall call) handler) {
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return handler(call);
    });
  }

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  group('keyFor', () {
    test('two variants of one IVA trailer get two keys; the token never counts', () {
      // Same path, different bytes: one key would mix their spans on disk.
      final hd = ReelClipCache.keyFor('server-a', '/services/iva/assets/87/video.mp4?fmt=4&bitrate=5000');
      final sd = ReelClipCache.keyFor('server-a', '/services/iva/assets/87/video.mp4?fmt=4&bitrate=2000');
      expect(hd, 'plex:server-a:/services/iva/assets/87/video.mp4;bitrate=5000;fmt=4');
      expect(sd, isNot(hd));
      expect(
        ReelClipCache.keyFor('server-a', '/services/iva/assets/87/video.mp4?bitrate=5000&X-Plex-Token=abc123&fmt=4'),
        hd,
      );
    });

    test('the server and the part path, never the address or a token', () {
      expect(
        ReelClipCache.keyFor('server-a', '/library/parts/41/1700000000/file.mp4'),
        'plex:server-a:/library/parts/41/1700000000/file.mp4',
      );
      expect(
        ReelClipCache.keyFor('server-a', '/library/parts/41/1700000000/file.mp4?X-Plex-Token=abc123'),
        'plex:server-a:/library/parts/41/1700000000/file.mp4',
      );
      expect(
        ReelClipCache.keyFor('server-a', '/services/iva/assets/87/video.mp4#t=3'),
        'plex:server-a:/services/iva/assets/87/video.mp4',
      );
    });

    test('nothing that could carry a secret, and nothing empty', () {
      expect(ReelClipCache.keyFor('server-a', '/x/token/abc123'), isNull);
      expect(ReelClipCache.keyFor('server-a', 'https://other.invalid/x.mp4'), isNull);
      expect(ReelClipCache.keyFor('server-a', '/x.mp4&a=b'), isNull);
      expect(ReelClipCache.keyFor('', '/x.mp4'), isNull);
      expect(ReelClipCache.keyFor('server-a', '?X-Plex-Token=abc123'), isNull);
    });
  });

  test('usage, clear and onDisk go over the channel', () async {
    answer(
      (call) => switch (call.method) {
        'usage' => {'bytes': 1024, 'capBytes': 2048},
        'clear' => 1024,
        'onDisk' => ['plex:server-a:/a'],
        _ => null,
      },
    );
    final cache = ReelClipCache(channel: channel, supported: true);
    final usage = await cache.usage();
    expect(usage?.bytes, 1024);
    expect(usage?.capBytes, 2048);
    expect(await cache.clear(), 1024);
    expect(await cache.onDisk(['plex:server-a:/a', 'plex:server-a:/b']), {'plex:server-a:/a'});
    expect(calls.last.arguments, {
      'keys': ['plex:server-a:/a', 'plex:server-a:/b'],
    });
    expect(await cache.isOnDisk('plex:server-a:/a'), isTrue);
    expect(await cache.isOnDisk(null), isFalse);
  });

  test('off Android, or with no channel, every answer is "nothing"', () async {
    answer((_) => throw StateError('never asked'));
    final off = ReelClipCache(channel: channel, supported: false);
    expect(await off.usage(), isNull);
    expect(await off.clear(), isNull);
    expect(await off.onDisk(['plex:server-a:/a']), isEmpty);
    expect(calls, isEmpty);

    messenger.setMockMethodCallHandler(channel, null);
    final missing = ReelClipCache(channel: channel, supported: true);
    expect(await missing.usage(), isNull);
    expect(await missing.isOnDisk('plex:server-a:/a'), isFalse);
  });

  test('a failing call is "nothing", not an error', () async {
    answer((_) => throw PlatformException(code: 'REEL_CACHE'));
    final cache = ReelClipCache(channel: channel, supported: true);
    expect(await cache.clear(), isNull);
    expect(await cache.onDisk(['plex:server-a:/a']), isEmpty);
  });
}
