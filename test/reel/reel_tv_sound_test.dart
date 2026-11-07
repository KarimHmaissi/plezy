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

/// The TV never starts the Reel with sound: every visit starts muted, the
/// card says so with the key that brings the sound in, and the sound rises
/// when it comes on. Back from Watch keeps what the viewer chose.
void main() {
  late ForkDatabase db;
  late ReelController c;
  late List<bool> watched;
  late List<FakeClipEngine> engines;
  late SettingsService settings;
  final key = GlobalKey<ReelScreenState>();

  setUp(() async {
    LocaleSettings.setLocaleSync(AppLocale.en);
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    TvDetectionService.debugSetAppleTVOverride(true);
    settings = await SettingsService.getInstance();
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
      // As the app builds it on the TV (ReelApp): muted until a visit says.
      clips: ClipPlayer(
        muted: true,
        engine: () {
          final e = FakeClipEngine();
          engines.add(e);
          return e;
        },
      ),
      store: store,
      media: _Media(),
      // The real Watch pushes the player over the shell, which hides the tab.
      onWatch: (_, {required onTv}) async {
        watched.add(onTv);
        key.currentState?.onTabHidden();
        return true;
      },
      onOpen: (_) async => key.currentState?.onTabHidden(),
      addToWatchlist: (_) async => true,
    );
  });

  tearDown(() async {
    TvDetectionService.debugSetAppleTVOverride(null);
    ReelScreen.requestedDeck.value = null;
    await db.close();
  });

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
  }

  Future<ReelScreenState> showTv(WidgetTester tester) async {
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

  Future<void> press(WidgetTester tester, LogicalKeyboardKey k) async {
    await tester.sendKeyEvent(k);
    await settle(tester);
  }

  /// The tab shown again, the shell having hidden it.
  Future<void> again(WidgetTester tester, ReelScreenState reel) async {
    reel.onTabShown();
    await settle(tester);
  }

  Future<void> soundOn(WidgetTester tester) async {
    await press(tester, LogicalKeyboardKey.contextMenu);
    expect(c.clips.muted, isFalse);
  }

  final soundOff = find.byKey(const ValueKey('reel-sound-off'));
  final soundOnBadge = find.byKey(const ValueKey('reel-sound-on'));

  /// Every level the clip core was sent, on every core this session built.
  List<double> levels() => [for (final e in engines) ...e.volumes];

  group('every TV visit starts muted', () {
    testWidgets('the app opened on the Reel: muted, nothing audible, and the sound button says how to get sound', (
      tester,
    ) async {
      await showTv(tester);
      await tester.pump(const Duration(seconds: 2));
      expect(c.clips.muted, isTrue);
      expect(levels(), everyElement(0), reason: 'not one level above silence');
      expect(soundOff, findsOneWidget);
      expect(find.text(t.reel.card.soundOn), findsOneWidget);
      expect(find.textContaining(t.reel.card.soundButtonKeys), findsOneWidget);
      expect(settings.read(SettingsService.reelMuted), isFalse, reason: "a visit's mute is never saved");
    });

    testWidgets('even when the sound was left on last time (the old TV started every clip at full volume)', (
      tester,
    ) async {
      await settings.write(SettingsService.reelMuted, false);
      final reel = await showTv(tester);
      await soundOn(tester);
      expect(settings.read(SettingsService.reelMuted), isFalse);

      reel.onTabHidden();
      await settle(tester);
      await again(tester, reel);
      expect(c.clips.muted, isTrue, reason: 'the Reel tab chosen again');
    });

    testWidgets('the app brought back after the Reel was let go (the Shield woken from standby)', (tester) async {
      await showTv(tester);
      await soundOn(tester);

      for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      await settle(tester);
      expect(c.active, isFalse);
      for (final s in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      await settle(tester);
      expect(c.active, isTrue);
      expect(c.clips.muted, isTrue);
      expect(soundOff, findsOneWidget);
    });

    testWidgets('back after a long standby, started afresh', (tester) async {
      var now = DateTime(2026, 1, 1, 9);
      ReelScreen.clock = () => now;
      addTearDown(() => ReelScreen.clock = DateTime.now);
      await showTv(tester);
      await soundOn(tester);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await settle(tester);
      now = now.add(ReelScreen.longAway + const Duration(minutes: 1));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settle(tester);
      await settle(tester);
      expect(c.clips.muted, isTrue);
    });

    testWidgets('a plezy://reel link onto a Reel the app let go', (tester) async {
      await showTv(tester);
      await soundOn(tester);
      for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      await settle(tester);
      expect(c.active, isFalse);

      // The link lands before the app is resumed, and starts the Reel: muted
      // from its first card.
      final from = engines.length;
      ReelScreen.requestedDeck.value = 'b';
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(c.active, isTrue);
      expect(c.clips.muted, isTrue);
      expect(engines.length, greaterThan(from), reason: 'a fresh core for the fresh visit');
      expect([for (final e in engines.skip(from)) ...e.volumes], everyElement(0));
      for (final s in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      await settle(tester);
      expect(c.deck.id, 'b');
      expect(c.clips.muted, isTrue);
    });

    testWidgets('a link that switches to the Reel tab', (tester) async {
      final reel = await showTv(tester);
      await soundOn(tester);
      reel.onTabHidden();
      await settle(tester);

      ReelScreen.requestedDeck.value = 'b';
      await settle(tester);
      await again(tester, reel);
      expect(c.deck.id, 'b');
      expect(c.clips.muted, isTrue);
    });

    testWidgets('a "With sound" stored before this change (the old page offered it on the TV, and a phone\'s comes '
        'in with a settings import) still starts muted', (tester) async {
      await settings.write(SettingsService.reelStartSound, ReelStartSound.sound);
      await showTv(tester);
      expect(c.clips.muted, isTrue);
      expect(soundOff, findsOneWidget);
    });

    testWidgets('"With sound" on the TV: the visit has sound, unless the mute was kept', (tester) async {
      await settings.write(SettingsService.reelTvStartSound, ReelStartSound.sound);
      final reel = await showTv(tester);
      expect(c.clips.muted, isFalse);
      expect(soundOff, findsNothing);
      expect(soundOnBadge, findsOneWidget, reason: 'the button offers Mute');

      await press(tester, LogicalKeyboardKey.contextMenu);
      await tester.tap(find.text(t.reel.sheet.soundOff));
      await settle(tester);
      expect(settings.read(SettingsService.reelMuted), isTrue);
      reel.onTabHidden();
      await settle(tester);
      await again(tester, reel);
      expect(c.clips.muted, isTrue);
    });
  });

  group('the same visit keeps the sound', () {
    testWidgets('back from Watch keeps the sound the viewer turned on; the next visit is muted again', (tester) async {
      final reel = await showTv(tester);
      await soundOn(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      await settle(tester);
      expect(watched, [false]);

      await again(tester, reel);
      expect(c.clips.muted, isFalse, reason: 'Back from the player');
      expect(soundOff, findsNothing);

      reel.onTabHidden();
      await settle(tester);
      await again(tester, reel);
      expect(c.clips.muted, isTrue, reason: 'the tab chosen later is a new visit');
    });

    testWidgets('back from Watch keeps a mute too', (tester) async {
      await settings.write(SettingsService.reelTvStartSound, ReelStartSound.sound);
      final reel = await showTv(tester);
      expect(c.clips.muted, isFalse);
      ReelScreen.remoteAction('mute');
      await settle(tester);
      expect(c.clips.muted, isTrue);
      await settings.write(SettingsService.reelMuted, false);

      ReelScreen.remoteAction('watch');
      await settle(tester);
      await again(tester, reel);
      expect(c.clips.muted, isTrue);
    });

    testWidgets('back from Details keeps the sound too', (tester) async {
      final reel = await showTv(tester);
      await soundOn(tester);
      ReelScreen.remoteAction('details');
      await settle(tester);
      await again(tester, reel);
      expect(c.clips.muted, isFalse);
    });

    testWidgets('a quick overlay over the player (only the focus gone) leaves it the same visit', (tester) async {
      final reel = await showTv(tester);
      await soundOn(tester);
      ReelScreen.remoteAction('watch');
      await settle(tester);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await settle(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settle(tester);

      await again(tester, reel);
      expect(c.clips.muted, isFalse);
    });
  });

  group('the app sent away while a page the Reel opened covers it: Back is a new visit', () {
    testWidgets('the Shield slept on the player and was woken: Back from it starts the Reel muted', (tester) async {
      final reel = await showTv(tester);
      await soundOn(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      await settle(tester);
      expect(watched, [false]);

      for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      await settle(tester);
      for (final s in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      await settle(tester);

      await again(tester, reel);
      expect(c.clips.muted, isTrue);
      expect(soundOff, findsOneWidget);
    });

    testWidgets('Details left up for a long time (a screensaver over it): Back starts the Reel muted', (tester) async {
      var now = DateTime(2026, 1, 1, 9);
      ReelScreen.clock = () => now;
      addTearDown(() => ReelScreen.clock = DateTime.now);
      final reel = await showTv(tester);
      await soundOn(tester);
      ReelScreen.remoteAction('details');
      await settle(tester);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await settle(tester);
      now = now.add(ReelScreen.longAway + const Duration(minutes: 1));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settle(tester);

      await again(tester, reel);
      expect(c.clips.muted, isTrue);
    });

    testWidgets('stepping between cards and decks never mutes again', (tester) async {
      await showTv(tester);
      await soundOn(tester);
      for (final k in [
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.mediaTrackNext,
      ]) {
        await press(tester, k);
        expect(c.clips.muted, isFalse, reason: '$k');
      }
      // A deck opened from the phone while the Reel plays is a deck change.
      ReelScreen.requestedDeck.value = 'b';
      await settle(tester);
      expect(c.deck.id, 'b');
      expect(c.clips.muted, isFalse);
    });

    testWidgets('and a muted Reel stays muted from card to card, the badge with it', (tester) async {
      await showTv(tester);
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(c.clips.muted, isTrue);
      expect(soundOff, findsOneWidget);
      expect(levels(), everyElement(0));
    });
  });

  group('turning the sound on', () {
    testWidgets('≡ turns it on; the sound button offers Mute; ≡ then opens the sheet', (tester) async {
      await showTv(tester);
      await press(tester, LogicalKeyboardKey.contextMenu);
      expect(c.clips.muted, isFalse);
      expect(find.text(t.reel.sheet.details), findsNothing, reason: 'the press was the sound key');
      expect(soundOnBadge, findsOneWidget);
      expect(find.text(t.reel.card.mute), findsOneWidget);
      expect(soundOff, findsNothing);
      expect(settings.read(SettingsService.reelMuted), isFalse);

      await press(tester, LogicalKeyboardKey.contextMenu);
      expect(find.text(t.reel.sheet.details), findsOneWidget);
    });

    testWidgets('the sound rises from silence instead of jumping to full', (tester) async {
      await showTv(tester);
      final engine = engines.last;
      engine.volumes.clear();
      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await tester.pump();
      expect(engine.volumes.where((v) => v >= 100), isEmpty);
      await tester.pump(ClipPlayer.unmuteRamp ~/ 2);
      expect(c.clips.level, inExclusiveRange(0, 100));
      await tester.pump(ClipPlayer.unmuteRamp);
      expect(c.clips.level, 100);
      expect(engine.volumes.first, lessThan(ClipPlayer.dipLevel));
    });

    testWidgets('the sound button stays through quiet mode while muted', (tester) async {
      await showTv(tester);
      final engine = engines.last;
      engine.firstFrameCtl.add(null);
      await tester.pump(const Duration(seconds: 8));
      expect(soundOff, findsOneWidget);
    });

    testWidgets('a screen reader hears it', (tester) async {
      final semantics = tester.ensureSemantics();
      await showTv(tester);
      expect(
        tester.getSemantics(find.descendant(of: soundOff, matching: find.byType(Semantics)).first),
        matchesSemantics(
          label: t.reel.card.soundOffAnnounce,
          isLiveRegion: true,
          isButton: true,
          isFocusable: true,
          hasTapAction: true,
        ),
      );
      semantics.dispose();
    });

    testWidgets('On TV mode: mute and volume up from the phone turn it on too', (tester) async {
      await showTv(tester);
      ReelScreen.remoteAction('mute');
      await settle(tester);
      expect(c.clips.muted, isFalse);
      expect(soundOnBadge, findsOneWidget);

      ReelScreen.remoteAction('mute');
      await settle(tester);
      expect(c.clips.muted, isTrue);
      expect(soundOff, findsOneWidget);

      ReelScreen.remoteAction('volumeUp');
      await settle(tester);
      expect(c.clips.muted, isFalse);
    });

    testWidgets('Sound on in the sheet (hold OK) turns it on too', (tester) async {
      await showTv(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      // The sheet's entry (the sound button says "Sound on" too, under it).
      await tester.tap(find.text(t.reel.card.soundOn).last);
      await settle(tester);
      expect(c.clips.muted, isFalse);
    });
  });
}
