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
import 'package:plezy/services/reel/reel_controller.dart';
import 'package:plezy/services/reel/reel_decks.dart';
import 'package:plezy/services/reel/reel_library.dart';
import 'package:plezy/services/reel/reel_store.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:provider/provider.dart';

import '../test_helpers/prefs.dart';
import 'clip_player_test.dart' show FakeClipEngine;

/// The Fold's link to a TV, switched by the test; records what it sends.
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

class _Servers implements ReelServers {
  @override
  Future<List<PlexExtraClip>> extras(String serverId, String ratingKey, {required Duration timeout}) async => [];

  @override
  String? clipUrl(String serverId, String partKey) => null;
}

class _Media implements ReelMedia {
  @override
  Future<MediaItem?> item(String serverId, String ratingKey) async =>
      MediaItem(id: ratingKey, backend: MediaBackend.plex, kind: MediaKind.movie, title: 'x', serverId: serverId);

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

/// V2-48 on the Fold: On TV mode and "Watch here" follow the connection,
/// and On TV mode opens the TV on the card the phone is on.
void main() {
  late ForkDatabase db;
  late ReelStore store;
  late ReelController c;
  late List<bool> watched;
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
      externalClips: true,
    );
  });

  tearDown(() => db.close());

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

  testWidgets('host: an open from the Fold lands on its card, or on the deck\'s cursor without one', (tester) async {
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
}
