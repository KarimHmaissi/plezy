import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/fork_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/models/companion_remote/remote_command.dart';
import 'package:plezy/providers/companion_remote_provider.dart';
import 'package:plezy/screens/reel/reel_remote_view.dart';
import 'package:plezy/screens/reel/reel_screen.dart';
import 'package:plezy/services/ai/facts/title_facts.dart';
import 'package:plezy/services/customisation/customisation_store.dart';
import 'package:plezy/services/library_index/index_database.dart';
import 'package:plezy/services/reel/clip_filter.dart';
import 'package:plezy/services/reel/clip_player.dart';
import 'package:plezy/services/reel/clip_resolver.dart';
import 'package:plezy/services/reel/feed_players.dart';
import 'package:plezy/services/reel/reel_controller.dart';
import 'package:plezy/services/reel/reel_decks.dart';
import 'package:plezy/services/reel/reel_library.dart';
import 'package:plezy/services/reel/reel_store.dart';
import 'package:plezy/services/reel/reel_volume.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:provider/provider.dart';

import '../test_helpers/prefs.dart';
import 'clip_player_test.dart' show FakeClipEngine;

/// The phone's link to a TV, switched by the test; records what it sends.
class _Remote extends CompanionRemoteProvider {
  bool connected = false;
  final sent = <(RemoteCommandType, Map<String, dynamic>?)>[];

  void link(bool on) {
    connected = on;
    notifyListeners();
  }

  @override
  bool get isRemote => connected;

  @override
  bool get isConnected => connected;

  @override
  void sendCommand(RemoteCommandType type, {Map<String, dynamic>? data}) => sent.add((type, data));
}

/// A feed player that opens at once and plays (the plugin's can't open a
/// clip in a widget test).
class _PlayingVideo extends ChangeNotifier implements FeedVideo {
  bool _ready = false, _playing = false;
  @override
  bool get ready => _ready;
  @override
  bool get failed => false;
  @override
  double get aspectRatio => 16 / 9;
  @override
  Duration get position => Duration.zero;
  @override
  Duration get duration => const Duration(seconds: 60);
  @override
  bool get playing => _playing;
  @override
  bool get buffering => false;
  @override
  bool get completed => false;
  @override
  Duration get buffered => duration;
  @override
  Future<void> initialize() async => _ready = true;
  @override
  Future<void> play() async => _playing = true;
  @override
  Future<void> pause() async => _playing = false;
  @override
  Future<void> seekTo(Duration position) async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> setLooping(bool looping) async {}
  @override
  Future<void> dispose() async => super.dispose();
  @override
  Widget view() => const SizedBox.shrink();
}

/// Whether the servers have trailers for every title (off by default).
var _withClips = false;

class _Servers implements ReelServers {
  /// Two per title: the plugin's players can't open a clip in a widget test,
  /// and a clip that fails is looked up once more without it (V2-56); a
  /// card whose second clip fails too becomes an AI card. Tests that need a
  /// clip card to stay one hand the screen players that open
  /// ([ReelScreen.debugFeedVideo]).
  @override
  Future<List<PlexExtraClip>> extras(String serverId, String ratingKey, {required Duration timeout}) async => [
    if (_withClips)
      for (final n in [1, 2])
        PlexExtraClip(
          ratingKey: 'x$ratingKey-$n',
          title: 'Trailer $n',
          partKey: '/services/iva/assets/$ratingKey-$n/video.mp4',
          subtype: 'trailer',
          index: n,
        ),
  ];

  @override
  String? clipUrl(String serverId, String partKey) => _withClips ? 'https://$serverId.example$partKey' : null;
}

class _Media implements ReelMedia {
  @override
  Future<MediaItem?> item(String serverId, String ratingKey) async =>
      MediaItem(id: ratingKey, backend: MediaBackend.plex, kind: MediaKind.movie, title: 'x', serverId: serverId);

  @override
  Future<MediaItem?> fullItem(String serverId, String ratingKey) => item(serverId, ratingKey);

  @override
  String? imageUrl(String serverId, String? path, {required int width}) => null;
}

class _Deck extends ReelDeck {
  _Deck(this.id, this.cards);

  @override
  final String id;
  final List<ReelCardData> cards;
  @override
  String get name => 'Deck $id';
  @override
  bool get keepsSeen => true;
  @override
  bool get raw => true;
  @override
  Future<List<ReelCardData>> load() async => cards;
}

ReelCardData _card(String id, String title) => ReelCardData(
  title: ReelTitle(
    titleId: 't$id',
    groupKey: 'g$id',
    title: title,
    isShow: false,
    copies: [ReelCopy(serverId: 's1', ratingKey: id)],
  ),
  facts: TitleFacts(
    ref: TitleRef(id: 't$id', groupKey: 'g$id'),
    seen: SeenState.unseen,
  ),
  best: IndexedTitle(
    id: 's1:$id',
    serverId: 's1',
    serverName: 'Server A',
    libraryKey: '1',
    libraryTitle: 'Films',
    ratingKey: id,
    type: 'movie',
    title: title,
    genres: '',
    countries: '',
    directors: '',
    writers: '',
    cast: '',
    collections: '',
    groupKey: 'g$id',
    summary: '',
  ),
);

/// V2-48 on the phone: On TV mode and "Watch here" follow the connection,
/// and On TV mode opens the TV on the card the phone is on.
void main() {
  late ForkDatabase db;
  late ReelStore store;
  late ReelController c;
  late List<bool> watched;
  late List<MediaItem> opened;
  final key = GlobalKey<ReelScreenState>();

  setUp(() async {
    LocaleSettings.setLocaleSync(AppLocale.en);
    // The remote provider listens for network changes; no plugin in tests.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity_status'),
      (_) async => null,
    );
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    final settings = await SettingsService.getInstance();
    await settings.write(SettingsService.reelIntroSeen, true);
    db = ForkDatabase.memory();
    final custom = LocalCustomisationStore(db);
    store = ReelStore(database: () async => db, settings: () async => custom);
    watched = [];
    opened = [];
    _withClips = false;
    ReelVolume.reset();
    c = ReelController(
      decks: [
        _Deck('a', [_card('1', 'Harbor Lights'), _card('2', 'Lantern Bay')]),
        _Deck('b', [_card('3', 'Quiet Orchard'), _card('4', 'Salt Road'), _card('5', 'Copper Hill')]),
      ],
      resolver: ClipResolver(
        servers: _Servers(),
        store: store,
        aniList: (_) async => null,
        animeThemes: (_) async => const {},
      ),
      clips: ClipPlayer(engine: FakeClipEngine.new),
      store: store,
      media: _Media(),
      onWatch: (_, {required onTv}) async {
        watched.add(onTv);
        return true;
      },
      addToWatchlist: (_) async => true,
      onOpen: (item) async => opened.add(item),
      externalClips: true,
    );
  });

  tearDown(() {
    ReelScreen.debugFeedVideo = null;
    return db.close();
  });

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
  }

  Future<(_Remote, ReelScreenState)> show(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 860);
    addTearDown(tester.view.reset);
    final remote = _Remote();
    addTearDown(remote.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<CompanionRemoteProvider>.value(
        value: remote,
        child: MaterialApp(
          theme: monoTheme(MonoPalette.dark),
          home: Scaffold(
            body: ReelScreen(key: key, create: (_) async => c),
          ),
        ),
      ),
    );
    final state = key.currentState!..onTabShown();
    await settle(tester);
    return (remote, state);
  }

  Finder onTv() => find.byTooltip(t.reel.card.onTv);

  testWidgets('the On TV button comes and goes with the connection, without leaving the Reel', (tester) async {
    final (remote, _) = await show(tester);
    expect(c.current.card?.title.title, 'Harbor Lights');
    expect(onTv(), findsNothing);

    remote.link(true);
    await tester.pumpAndSettle();
    expect(onTv(), findsOneWidget);

    remote.link(false);
    await tester.pumpAndSettle();
    expect(onTv(), findsNothing);
  });

  testWidgets('On TV mode opens the TV on the deck and the card the phone is on', (tester) async {
    // Clip cards: the phone holds back an AI card ahead (V2-37).
    _withClips = true;
    final (remote, _) = await show(tester);
    await c.step(1);
    remote.link(true);
    await settle(tester);
    await tester.tap(onTv());
    // The On TV page waits on the TV with a spinner: pump, don't settle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(ReelRemoteView), findsOneWidget);
    final open = remote.sent.lastWhere((s) => s.$1 == RemoteCommandType.reelOpen);
    expect(open.$2, {'deck': 'a', 'groupKey': 'g2'});
  });

  testWidgets('connected: "Watch here" in More plays the title on the phone', (tester) async {
    final (remote, _) = await show(tester);
    remote.link(true);
    await settle(tester);
    // Long-press lives on the picture, above the title block.
    await tester.longPressAt(const Offset(210, 330));
    await tester.pumpAndSettle();

    await tester.tap(find.text(t.reel.sheet.watchHere).last);
    await settle(tester);
    expect(watched, [false]);
  });

  testWidgets('host: an open from the phone lands on its card, or on the deck\'s cursor without one', (tester) async {
    final (_, state) = await show(tester);
    unawaited(state.openDeck('b', groupKey: 'g5'));
    await settle(tester);
    expect(c.deck.id, 'b');
    expect(c.current.card?.title.title, 'Copper Hill');

    unawaited(state.openDeck('a', groupKey: 'g-not-here'));
    await settle(tester);
    expect(c.deck.id, 'a');
    expect(c.current.card?.title.title, 'Harbor Lights');
  });

  group('V2-49 host: the full remote\'s actions', () {
    Future<List<String>> actions() async => [for (final e in await store.events(since: DateTime(2000))) e.action];

    testWidgets('Seen it and Details from the phone act on the TV\'s card', (tester) async {
      await show(tester);
      ReelScreen.remoteAction('seenIt');
      await settle(tester);
      expect(await tester.runAsync(actions), contains(ReelAction.seenIt.name));

      ReelScreen.remoteAction('details');
      await settle(tester);
      expect(opened.single.id, '1');
      expect(await tester.runAsync(actions), contains(ReelAction.details.name));
    });

    testWidgets('Spoiled me needs a clip, and the state tells the phone whether there is one', (tester) async {
      _withClips = true;
      // Clips that open: a card whose clips all fail becomes an AI card.
      ReelScreen.debugFeedVideo = (_) => _PlayingVideo();
      await show(tester);
      expect(c.remoteState()['hasClip'], isTrue);
      ReelScreen.remoteAction('spoiled');
      await settle(tester);
      expect(await tester.runAsync(actions), contains(ReelAction.spoiled.name));
    });

    testWidgets('mute toggles the Reel\'s sound; volume moves its level, and up brings the sound back', (tester) async {
      await show(tester);
      expect(c.remoteState()['muted'], isFalse);
      ReelScreen.remoteAction('mute');
      await settle(tester);
      expect(c.clips.muted, isTrue);
      expect(c.remoteState()['muted'], isTrue);

      ReelScreen.remoteAction('volumeDown');
      ReelScreen.remoteAction('volumeDown');
      await settle(tester);
      expect(ReelVolume.level.value, 80);
      expect(c.clips.muted, isTrue);

      ReelScreen.remoteAction('volumeUp');
      await settle(tester);
      expect(ReelVolume.level.value, 90);
      expect(c.clips.muted, isFalse);
    });
  });
}
