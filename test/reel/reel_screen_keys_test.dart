// The fake engines' controllers are closed with the player.
// ignore_for_file: close_sinks
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/fork_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
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
import 'package:plezy/services/reel/reel_volume.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/platform_detector.dart';

import '../test_helpers/prefs.dart';
import 'clip_player_test.dart' show FakeClipEngine;

class _Servers implements ReelServers {
  @override
  Future<List<PlexExtraClip>> extras(String serverId, String ratingKey, {required Duration timeout}) async => [
    PlexExtraClip(
      ratingKey: 'x$ratingKey',
      title: 'Trailer',
      partKey: '/services/iva/assets/$ratingKey/video.mp4',
      subtype: 'trailer',
    ),
  ];

  @override
  String? clipUrl(String serverId, String partKey) => 'https://$serverId.example$partKey';
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

/// V2-62: the TV's key map and long-press sheet, and the Reel letting go
/// of its player when the app leaves the screen.
void main() {
  late ForkDatabase db;
  late ReelController c;
  late List<bool> watched;
  late List<FakeClipEngine> engines;
  final key = GlobalKey<ReelScreenState>();

  setUp(() async {
    LocaleSettings.setLocaleSync(AppLocale.en);
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    final settings = await SettingsService.getInstance();
    await settings.write(SettingsService.reelIntroSeen, true);
    db = ForkDatabase.memory();
    final custom = LocalCustomisationStore(db);
    final store = ReelStore(database: () async => db, settings: () async => custom);
    watched = [];
    engines = [];
    ReelVolume.reset();
    c = ReelController(
      decks: [
        _Deck('a', [_card('1', 'Harbor Lights'), _card('2', 'Lantern Bay')]),
        _Deck('b', [_card('3', 'Quiet Orchard'), _card('4', 'Salt Road')]),
      ],
      resolver: ClipResolver(
        servers: _Servers(),
        store: store,
        aniList: (_) async => null,
        animeThemes: (_) async => const {},
      ),
      clips: ClipPlayer(
        engine: () {
          final e = FakeClipEngine();
          engines.add(e);
          return e;
        },
      ),
      store: store,
      media: _Media(),
      onWatch: (_, {required onTv}) async {
        watched.add(onTv);
        return true;
      },
      addToWatchlist: (_) async => true,
    );
  });

  tearDown(() async {
    TvDetectionService.debugSetAppleTVOverride(null);
    await db.close();
  });

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
  }

  /// The Reel tab on the TV, shown by the shell and holding focus.
  Future<ReelScreenState> showTv(WidgetTester tester) async {
    TvDetectionService.debugSetAppleTVOverride(true);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 720);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: monoTheme(MonoPalette.dark),
        home: Scaffold(
          body: ReelScreen(key: key, create: (_) async => c),
        ),
      ),
    );
    final state = key.currentState!..onTabShown();
    await settle(tester);
    state.focusActiveTabIfReady();
    await tester.pump();
    return state;
  }

  String? title() => c.current.card?.title.title;

  Future<bool> press(WidgetTester tester, LogicalKeyboardKey k) async {
    final handled = await tester.sendKeyEvent(k);
    await settle(tester);
    return handled;
  }

  group('TV key map', () {
    testWidgets('down and up step through the deck; right and left change deck', (tester) async {
      await showTv(tester);
      expect((c.deck.id, title()), ('a', 'Harbor Lights'));

      expect(await press(tester, LogicalKeyboardKey.arrowDown), isTrue);
      expect(title(), 'Lantern Bay');
      expect(await press(tester, LogicalKeyboardKey.arrowUp), isTrue);
      expect(title(), 'Harbor Lights');

      expect(await press(tester, LogicalKeyboardKey.arrowRight), isTrue);
      expect((c.deck.id, title()), ('b', 'Quiet Orchard'));
      expect(await press(tester, LogicalKeyboardKey.arrowLeft), isTrue);
      expect(c.deck.id, 'a');
    });

    testWidgets('play/pause keys reach the clip; Back goes to the sound button, then on to the shell', (tester) async {
      await showTv(tester);
      final engine = engines.last;
      engine.calls.clear();

      expect(await press(tester, LogicalKeyboardKey.mediaPause), isTrue);
      expect(engine.calls, contains('pause'));
      expect(await press(tester, LogicalKeyboardKey.mediaPlay), isTrue);
      expect(engine.calls, contains('play'));

      expect(await press(tester, LogicalKeyboardKey.escape), isTrue, reason: 'the first Back is the sound button');
      expect(find.byKey(const ValueKey('reel-sound-focus')), findsOneWidget);
      expect(
        await press(tester, LogicalKeyboardKey.escape),
        isFalse,
        reason: 'then Back belongs to the shell (the rail)',
      );
      expect(find.byKey(const ValueKey('reel-sound-focus')), findsNothing);
      expect((c.deck.id, title()), ('a', 'Harbor Lights'));
    });

    testWidgets('OK pressed and let go watches the card', (tester) async {
      await showTv(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      await settle(tester);

      expect(watched, [false]);
      expect(find.text(t.reel.sheet.details), findsNothing);
    });
  });

  group('TV long-press sheet', () {
    testWidgets('holding OK opens the sheet instead of watching', (tester) async {
      await showTv(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(find.text(t.reel.sheet.details), findsOneWidget);
      expect(find.text(t.reel.sheet.seenIt), findsOneWidget);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();

      expect(watched, isEmpty, reason: 'the release of a long press does not watch');
    });

    testWidgets('the menu key opens it too, and Not for me moves on from the card', (tester) async {
      await showTv(tester);

      // The TV starts muted, and ≡ on a muted card is the sound key first.
      expect(c.clips.muted, isTrue);
      expect(await press(tester, LogicalKeyboardKey.contextMenu), isTrue);
      expect(c.clips.muted, isFalse);
      expect(find.text(t.reel.sheet.details), findsNothing);

      expect(await press(tester, LogicalKeyboardKey.contextMenu), isTrue);
      expect(find.text(t.reel.sheet.details), findsOneWidget);

      await tester.tap(find.text(t.reel.sheet.notForMe));
      await settle(tester);
      expect(find.text(t.reel.sheet.details), findsNothing);
      expect(title(), 'Lantern Bay');
      expect(watched, isEmpty);
    });
  });

  group('lifecycle', () {
    for (final state in [AppLifecycleState.paused, AppLifecycleState.hidden]) {
      testWidgets('${state.name}: the Reel stops and lets go of its player; resumed starts it again', (tester) async {
        await showTv(tester);
        expect(c.active, isTrue);
        final engine = engines.last;

        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        if (state == AppLifecycleState.paused) {
          tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        }
        tester.binding.handleAppLifecycleStateChanged(state);
        await settle(tester);
        expect(c.active, isFalse);
        expect(engine.disposed, isTrue, reason: 'no decoder held in the background');

        if (state == AppLifecycleState.paused) {
          tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        }
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await settle(tester);
        expect(c.active, isTrue);
        expect(title(), 'Harbor Lights', reason: 'back on the same card');
      });
    }

    testWidgets('a hidden tab ignores the app lifecycle', (tester) async {
      final reel = await showTv(tester);
      reel.onTabHidden();
      await settle(tester);
      expect(c.active, isFalse);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settle(tester);
      expect(c.active, isFalse, reason: 'resuming the app does not start a Reel nobody is looking at');
    });
  });
}
