import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_part.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/media_version.dart';
import 'package:plezy/media/server_capabilities.dart';
import 'package:plezy/models/transcode_quality_preset.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/providers/account_preferences_controller.dart';
import 'package:plezy/providers/companion_remote_provider.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/providers/playback_state_provider.dart';
import 'package:plezy/screens/video_player_screen.dart';
import 'package:plezy/services/broken_copies.dart';
import 'package:plezy/services/download_storage_service.dart';
import 'package:plezy/services/offline_watch_sync_service.dart';
import 'package:plezy/services/playback_coordinator.dart';
import 'package:plezy/services/playback_initialization_types.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/utils/external_ids.dart';
import 'package:plezy/utils/media_server_http_client.dart';
import 'package:plezy/watch_together/providers/watch_together_provider.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/io_fakes.dart';
import '../../test_helpers/media_items.dart';
import '../../test_helpers/mock_player_channels.dart';
import '../../test_helpers/multi_server_fixtures.dart';
import '../../test_helpers/playback_report_fakes.dart';
import '../../test_helpers/player_streams.dart';
import '../../test_helpers/prefs.dart';
import '../../test_helpers/pump.dart';
import '../../test_helpers/watch_together_fakes.dart';

/// Fork: a Plex open that fails before its first frame moves on to the
/// title's next copy, through the real screen and in-place reload, with a
/// deterministic player and two invented servers.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpRoot;
  late PathProviderPlatform previousPathProvider;
  late AppDatabase db;

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    DownloadStorageService.resetForTesting();
    await SettingsService.getInstance();
    tmpRoot = await Directory.systemTemp.createTemp('copy_fallback_player_test_');
    previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = FakePathProvider(tmpRoot);
    await DownloadStorageService.instance.initialize(SettingsService.instance);
    db = AppDatabase.forTesting(NativeDatabase.memory());
    BrokenCopies.instance.resetForTesting();
  });

  tearDown(() async {
    await db.close();
    DownloadStorageService.resetForTesting();
    SettingsService.resetForTesting();
    PathProviderPlatform.instance = previousPathProvider;
    if (await tmpRoot.exists()) await tmpRoot.delete(recursive: true);
  });

  MediaVersion version(String id, String resolution, int height, int bitrate) => MediaVersion(
    id: id,
    videoResolution: resolution,
    height: height,
    bitrate: bitrate,
    parts: [MediaPart(id: 'part-$id')],
  );

  MediaItem film(String id, String serverId, String serverName, List<MediaVersion> versions, {int? viewOffsetMs}) =>
      testMediaItem(
        id: id,
        viewOffsetMs: viewOffsetMs,
        kind: MediaKind.movie,
        title: 'Harbor Lights',
        year: 2019,
        serverId: serverId,
        serverName: serverName,
        mediaVersions: versions,
      );

  // The viewer stopped 10 minutes in on Server A; Server B never saw it.
  final onA = film('101', 'server-a', 'Server A', [
    version('a1080', '1080', 1080, 9000),
    version('a4k', '4k', 2160, 60000),
  ], viewOffsetMs: 600000);
  final onB = film('202', 'server-b', 'Server B', [
    version('b4k', '4k', 2160, 58000),
    version('b1080', '1080', 1080, 8500),
  ]);

  Future<({VideoPlayerScreenState state, _CopyPlayer player, _CopyServer a, _CopyServer b})> pumpPlayer(
    WidgetTester tester, {
    required bool opens,
    bool firstFrame = true,
    bool matchesDisplay = false,
  }) async {
    final a = _CopyServer('server-a', 'Server A', copy: onA);
    final b = _CopyServer('server-b', 'Server B', copy: onB);
    final multi = testMultiServer(clients: [a, b]);
    final offlineWatch = OfflineWatchSyncService(database: db, serverManager: multi.manager);
    final accountPreferences = AccountPreferencesController();
    // Hold the screen's own start, so the test owns every open.
    final hold = Completer<void>();
    Future<void> holdStart() => hold.future;
    PlaybackCoordinator.instance.registerMusicSession(stopAndDispose: holdStart);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      PlaybackCoordinator.instance.unregisterMusicSession(holdStart);
      if (!hold.isCompleted) hold.complete();
      await tester.pump();
      offlineWatch.dispose();
      accountPreferences.dispose();
    });
    final key = GlobalKey<VideoPlayerScreenState>();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => PlaybackStateProvider()),
          ChangeNotifierProvider<MultiServerProvider>.value(value: multi.provider),
          ChangeNotifierProvider<OfflineWatchSyncService>.value(value: offlineWatch),
          ChangeNotifierProvider<AccountPreferencesController>.value(value: accountPreferences),
          ChangeNotifierProvider<WatchTogetherProvider>(create: (_) => WatchTogetherProvider()),
          Provider<AppDatabase>.value(value: db),
          ChangeNotifierProvider(create: (_) => CompanionRemoteProvider()),
        ],
        child: MaterialApp(
          home: VideoPlayerScreen(
            key: key,
            metadata: onA,
            // Play's default: the highest-bitrate version, the 4K.
            selectedMediaIndex: 1,
            selectedQualityPreset: TranscodeQualityPreset.original,
          ),
        ),
      ),
    );
    final player = _CopyPlayer(opens: opens, firstFrame: firstFrame, matchesDisplay: matchesDisplay);
    addTearDown(player.dispose);
    key.currentState!.player = player;
    await key.currentState!.debugWirePlayerStreamsForTesting();
    return (state: key.currentState!, player: player, a: a, b: b);
  }

  testWidgets('a 503 before the first frame opens the same quality on the other server, at the same position', (
    tester,
  ) async {
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      testBody: () async {
        final (:state, :player, :a, :b) = await pumpPlayer(tester, opens: true);

        player.emitError(const PlayerError('Stream unavailable', cause: PlayerError.serverHttp503));
        await pumpUntil(tester, () => player.openedUris.isNotEmpty, describe: () => '${player.openedUris}');

        expect(player.openedUris.single, 'https://example.invalid/server-b/202');
        expect(b.picks, ['b4k'], reason: 'the same 4K, on Server B');
        expect(a.picks, isEmpty, reason: "the failing server's 1080p goes after the other server's copies");
        expect(player.openedStarts.single, const Duration(minutes: 10), reason: "where the viewer's open would start");
        expect(state.debugCurrentMetadataForTesting.globalKey, onB.globalKey);
        expect(
          state.debugToastTextForTesting,
          t.copies.trying(quality: '4K', location: 'Server B'),
          reason: 'the notice says what it is trying, and where',
        );
        expect(find.text(t.messages.serverBusyTitle), findsNothing);
        // The 4K on Server A is remembered as broken; Server B's, which
        // played, is not.
        expect(BrokenCopies.instance.isBroken('server-a|101|a4k'), isTrue);
        expect(BrokenCopies.instance.isBroken('server-b|202|b4k'), isFalse);

        await tester.pump(const Duration(seconds: 5));
      },
    );
  });

  testWidgets('when every copy fails, the dialog appears once, offering "Choose another copy"', (tester) async {
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      testBody: () async {
        final (:state, :player, :a, :b) = await pumpPlayer(tester, opens: false);

        player.emitError(const PlayerError('Stream unavailable', cause: PlayerError.serverHttp503));
        await pumpUntil(tester, () => find.text(t.messages.serverBusyTitle).evaluate().isNotEmpty);

        // Server B's 4K, then its 1080p, then Server A's 1080p: three attempts.
        expect(b.picks, ['b4k', 'b1080']);
        expect(a.picks, ['a1080']);
        expect(player.openCalls, 3);
        expect(find.text(t.copies.chooseAnother), findsOneWidget);
        expect(find.text(t.messages.serverBusyTitle), findsOneWidget);

        await tester.tap(find.text(t.common.close));
        await tester.pump(const Duration(seconds: 5));
      },
    );
  });

  // With display matching on (the Shield), each open waits, paused, inside
  // its in-place reload for the first frame. A copy that opens and then fails
  // (503 for the whole window) is still inside that reload when the failure
  // arrives; the next copy must still be tried, not turned away while the
  // failed reload lets go of the player.
  testWidgets('a copy that opens and then fails behind the display-matching hold moves on to the next', (tester) async {
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      testBody: () async {
        await SettingsService.instance.write(SettingsService.matchContentFrameRate, true);
        final (:state, :player, :a, :b) = await pumpPlayer(
          tester,
          opens: true,
          firstFrame: false,
          matchesDisplay: true,
        );

        player.emitError(const PlayerError('Stream unavailable', cause: PlayerError.serverHttp503));
        await pumpUntil(tester, () => player.openedUris.isNotEmpty, describe: () => '${player.openedUris}');
        expect(player.openedUris.single, 'https://example.invalid/server-b/202');

        // Server B's 4K opens, then answers 503 for the whole window too.
        player.emitError(const PlayerError('Stream unavailable', cause: PlayerError.serverHttp503));
        await pumpUntil(
          tester,
          () => player.openedUris.length > 1 || find.text(t.messages.serverBusyTitle).evaluate().isNotEmpty,
          describe: () => '${player.openedUris}',
        );

        expect(find.text(t.messages.serverBusyTitle), findsNothing, reason: 'two 1080p copies are still to try');
        expect(player.openedUris, [
          'https://example.invalid/server-b/202',
          'https://example.invalid/server-a/101',
        ], reason: 'then the next quality down, the highest bitrate first');
        expect(a.picks, ['a1080']);
        expect(state.debugCurrentMetadataForTesting.globalKey, onA.globalKey);

        // Leave while that copy still waits for its first frame: the screen
        // lets go of the open before the player is closed.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 3));
      },
    );
  });

  // A film that failed after it had played goes on from where it stopped on
  // the copy picked from the failure view, as Retry does, not from where
  // its open started.
  testWidgets('another copy picked after a failure mid-film resumes at the playhead', (tester) async {
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      testBody: () async {
        final (:state, :player, :a, :b) = await pumpPlayer(tester, opens: true);

        // Server A's 4K fails; Server B's opens 10 minutes in and plays.
        player.emitError(const PlayerError('Stream unavailable', cause: PlayerError.serverHttp503));
        await pumpUntil(tester, () => player.openedUris.isNotEmpty, describe: () => '${player.openedUris}');
        expect(player.openedStarts.single, const Duration(minutes: 10));

        // 40 minutes in, the stream dies.
        player.setPosition(const Duration(minutes: 40));
        player.emitError(const PlayerError('Decoder failed'));
        await pumpUntil(tester, () => find.text(t.copies.chooseAnother).evaluate().isNotEmpty);

        await tester.tap(find.text(t.copies.chooseAnother));
        await pumpUntil(tester, () => find.text(t.copies.pickerTitle).evaluate().isNotEmpty);
        await tester.tap(find.textContaining(RegExp(r'^1080p.*Server A')));
        await pumpUntil(tester, () => player.openedUris.length > 1, describe: () => '${player.openedUris}');

        expect(player.openedUris.last, 'https://example.invalid/server-a/101');
        expect(a.picks, ['a1080']);
        expect(player.openedStarts.last, const Duration(minutes: 40), reason: 'where the film stopped');

        await tester.pump(const Duration(seconds: 5));
      },
    );
  });
}

class _CopyServer with PlaybackReportRecorder implements MediaServerClient {
  _CopyServer(this.id, this.name, {required this.copy});
  final String id;
  final String name;
  final MediaItem copy;
  final requests = <PlaybackInitializationOptions>[];

  /// Versions the copy fallback asked for by id (the screen's own prefetch
  /// at mount names none).
  List<String> get picks => [
    for (final r in requests)
      if (r.selectedMediaSourceId != null) r.selectedMediaSourceId!,
  ];
  final reports = <PlaybackReportCall>[];

  @override
  ServerId get serverId => ServerId(id);
  @override
  String get serverName => name;
  @override
  MediaBackend get backend => MediaBackend.plex;
  @override
  ServerCapabilities get capabilities => ServerCapabilities.plex;
  @override
  double get watchedThreshold => 0.9;
  @override
  bool get marksWatchedOnPlaybackStopped => false;
  @override
  Map<String, String> get streamHeaders => const {};
  @override
  Future<ExternalIds> fetchExternalIds(String itemId) async => const ExternalIds();

  @override
  Future<List<MediaItem>> searchItems(
    String query, {
    int limit = 100,
    AbortController? abort,
    Set<String> excludedLibraryIds = const {},
  }) async => [copy];

  @override
  Future<PlaybackInitializationResult> getPlaybackInitialization(PlaybackInitializationOptions options) async {
    requests.add(options);
    final versions = copy.mediaVersions!;
    final index = versions.indexWhere((v) => v.id == options.selectedMediaSourceId);
    return PlaybackInitializationResult(
      availableVersions: versions,
      videoUrl: 'https://example.invalid/$id/${options.metadata.id}',
      selectedMediaIndex: index < 0 ? options.selectedMediaIndex : index,
    );
  }

  @override
  Future<void> onPlaybackReport(PlaybackReportCall call) async => reports.add(call);

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CopyPlayer extends FakeSyncPlayer {
  _CopyPlayer({required this.opens, this.firstFrame = true, this.matchesDisplay = false})
    : super(playing: false, duration: const Duration(minutes: 100));
  final bool opens;

  /// Whether an open gets as far as its first frame; when false the load
  /// starts and then hangs, as a stream the server keeps refusing does.
  final bool firstFrame;

  /// Android mpv with display matching on: every open waits, paused, for its
  /// first frame before the reload that started it lets go of the player.
  final bool matchesDisplay;

  final _silent = StreamController<void>.broadcast();

  @override
  Future<void> dispose({bool preserveDisplayMode = false}) async {
    // Not awaited: its done event waits on listeners the screen's teardown
    // has no reason to finish first.
    unawaited(_silent.close());
    await super.dispose(preserveDisplayMode: preserveDisplayMode);
  }

  /// With [matchesDisplay], load signals that stay open as a real core's do,
  /// so an open's outcome waits for its first frame (or an abort) instead of
  /// settling the moment it subscribes to a closed stream.
  @override
  PlayerStreams get streams {
    final base = super.streams;
    if (!matchesDisplay) return base;
    return emptyPlayerStreams(
      playing: base.playing,
      buffering: base.buffering,
      duration: base.duration,
      rate: base.rate,
      error: base.error,
      playbackRestart: base.playbackRestart,
      fileStarted: base.fileStarted,
      fileLoaded: _silent.stream,
      fileLoadFailed: _silent.stream,
      primaryMediaReady: _silent.stream,
    );
  }

  int openCalls = 0;
  final openedUris = <String>[];
  final openedStarts = <Duration?>[];

  @override
  Future<void> stop() async => emitPlaying(false);

  @override
  String get playerType => 'mpv';

  @override
  bool get needsDecoderRefreshAfterDisplaySwitch => matchesDisplay;

  @override
  Future<void> setProperty(String name, String value) async {}

  @override
  Future<String?> getProperty(String name) async => null;

  @override
  Future<void> updateFrame() async {}

  @override
  Future<void> awaitDisplayModeSwitch({int extraDelayMs = 0}) async {}

  @override
  Future<bool> requestAudioFocus() async => true;

  @override
  Future<void> open(
    Media media, {
    bool play = true,
    bool isLive = false,
    List<SubtitleTrack>? externalSubtitles,
    Duration? timelineDuration,
    Duration timelineOffset = Duration.zero,
  }) async {
    openCalls++;
    if (!opens) throw StateError('the server would not hand over this file');
    openedUris.add(media.uri);
    openedStarts.add(media.start);
    setPosition(media.start ?? Duration.zero);
    emitPlaying(play);
    emitFileStarted();
    if (firstFrame) emitPlaybackRestart();
  }

  @override
  Future<void> selectSubtitleTrack(SubtitleTrack track) async {}
}
