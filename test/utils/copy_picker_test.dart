import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/copy_fallback.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_part.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/media_stream.dart';
import 'package:plezy/media/media_version.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/utils/copy_picker.dart';
import 'package:provider/provider.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/multi_server_fixtures.dart';

class _Server implements MediaServerClient {
  _Server(this.id);
  final String id;
  @override
  ServerId get serverId => ServerId(id);
  @override
  MediaBackend get backend => MediaBackend.plex;
  @override
  void close() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

MediaVersion _version(
  String id, {
  required String resolution,
  required int bitrate,
  int? sizeBytes,
  bool hdr = false,
  bool dv = false,
}) => MediaVersion(
  id: id,
  videoResolution: resolution,
  videoCodec: 'hevc',
  container: 'mkv',
  bitrate: bitrate,
  parts: [
    MediaPart(
      id: 'p$id',
      sizeBytes: sizeBytes,
      streams: [if (hdr || dv) MediaStream(id: 's$id', kind: MediaStreamKind.video, hdr: hdr || dv, dolbyVision: dv)],
    ),
  ],
);

void main() {
  final onA = testMediaItem(
    id: '101',
    title: 'Harbor Lights',
    serverId: 'server-a',
    serverName: 'Server A',
    libraryTitle: 'Films',
    mediaVersions: [
      _version('a4k', resolution: '4k', bitrate: 60000, sizeBytes: 60 * 1024 * 1024 * 1024, dv: true),
      _version('a1080', resolution: '1080', bitrate: 9000),
    ],
  );
  final onB = testMediaItem(
    id: '202',
    title: 'Harbor Lights',
    serverId: 'server-b',
    serverName: 'Server B',
    libraryTitle: 'Movies 4K',
    mediaVersions: [_version('b4k', resolution: '4k', bitrate: 58000, hdr: true)],
  );
  final offline = testMediaItem(
    id: '303',
    serverId: 'server-c',
    serverName: 'Server C',
    mediaVersions: [_version('c4k', resolution: '4k', bitrate: 90000)],
  );

  test('a row states quality and bitrate, HDR or Dolby Vision, size, library and server', () {
    expect(
      copySourceChoiceLabel(CopySource(onA, 0)),
      '4K HEVC MKV (60.0 Mbps) • ${t.fileInfo.dolbyVision} • 60.00 GB • Films • Server A',
    );
    expect(copySourceChoiceLabel(CopySource(onB, 0)), contains(' • ${t.videoSettings.hdr} • Movies 4K • Server B'));
    expect(copySourceChoiceLabel(CopySource(onA, 1), didNotPlay: true), endsWith(t.copies.didNotPlayMark));
  });

  test("the file playing, else Play's default, is marked", () {
    expect(copySourceChoiceLabel(CopySource(onA, 1), isDefault: true), endsWith('Server A • ${t.copies.defaultMark}'));
    expect(
      copySourceChoiceLabel(CopySource(onA, 1), isDefault: true, isPlaying: true),
      endsWith('Server A • ${t.copies.playingMark}'),
    );
  });

  test('rows go highest bitrate first across every server', () {
    expect(copyPickerSources([onA, onB]).map((s) => s.key), [
      'server-a|101|a4k',
      'server-b|202|b4k',
      'server-a|101|a1080',
    ]);
  });

  testWidgets('the remote walks every online copy and picks one; failed ones are marked', (tester) async {
    final serverC = _Server('server-c');
    final multi = testMultiServer(clients: [_Server('server-a'), _Server('server-b'), serverC], offline: [serverC]);
    late BuildContext host;
    await tester.pumpWidget(
      ChangeNotifierProvider<MultiServerProvider>.value(
        value: multi.provider,
        child: InputModeTracker(
          child: MaterialApp(
            home: Builder(
              builder: (context) {
                host = context;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      ),
    );
    // A remote press puts the app in D-pad mode, as on the TV.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    final picked = showCopyPicker(
      host,
      item: onA,
      copies: [onA, onB, offline],
      didNotPlay: (source) => source.key == 'server-a|101|a4k',
    );
    await tester.pumpAndSettle();

    expect(find.text(t.copies.pickerTitle), findsOneWidget);
    expect(find.textContaining('Server C'), findsNothing, reason: 'an offline server cannot play');
    expect(find.textContaining('Server B'), findsOneWidget);
    expect(find.textContaining(t.copies.didNotPlayMark), findsOneWidget);

    // First row has the focus; one step down is Server B's 4K.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect((await picked)?.key, 'server-b|202|b4k');
  });

  testWidgets("Play's default is listed first, so the remote's first OK is the file Play would open", (tester) async {
    final multi = testMultiServer(clients: [_Server('server-a'), _Server('server-b')]);
    late BuildContext host;
    await tester.pumpWidget(
      ChangeNotifierProvider<MultiServerProvider>.value(
        value: multi.provider,
        child: InputModeTracker(
          child: MaterialApp(
            home: Builder(
              builder: (context) {
                host = context;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    // The 4K failed, so Play's default is Server A's 1080p.
    final picked = showCopyPicker(host, item: onA, copies: [onA, onB], defaultSource: CopySource(onA, 1));
    await tester.pumpAndSettle();
    expect(find.textContaining(t.copies.defaultMark), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect((await picked)?.key, 'server-a|101|a1080');
  });
}
