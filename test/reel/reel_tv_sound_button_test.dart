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
import 'package:plezy/screens/reel/reel_card_view.dart' show ReelDeckStrip;
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
import 'package:plezy/screens/reel/reel_sound_button.dart';
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

/// The TV's sound button: always there bottom right, reached with Back
/// from the card (the card keeps OK and the d-pad), OK on it turns the
/// sound on or mutes, and it follows every other way the sound changes.
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
    TvDetectionService.debugSetTvOverride(null);
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

  final soundOff = find.byKey(const ValueKey('reel-sound-off'));
  final soundOnBadge = find.byKey(const ValueKey('reel-sound-on'));

  final ring = find.byKey(const ValueKey('reel-sound-focus'));
  String? title() => c.current.card?.title.title;

  Future<void> ok(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await settle(tester);
  }

  double opacity(WidgetTester tester) => tester
      .widget<AnimatedOpacity>(
        find.descendant(of: find.byType(ReelSoundButton), matching: find.byType(AnimatedOpacity)),
      )
      .opacity;

  group('on the card', () {
    testWidgets('muted on launch: "Sound on" bottom right inside the overscan, not focused; OK still watches', (
      tester,
    ) async {
      await showTv(tester);
      expect(c.clips.muted, isTrue);
      expect(soundOff, findsOneWidget);
      expect(find.descendant(of: soundOff, matching: find.text(t.reel.card.soundOn)), findsOneWidget);
      expect(ring, findsNothing, reason: 'the card keeps the focus');

      final rect = tester.getRect(soundOff);
      expect(rect.right, lessThanOrEqualTo(1280 * (1 - ReelDeckStrip.overscan)));
      expect(rect.bottom, lessThanOrEqualTo(720 * (1 - ReelDeckStrip.overscan)));
      expect(rect.left, greaterThan(1280 / 2), reason: 'on the right');
      expect(rect.top, greaterThan(720 * 0.75), reason: 'at the bottom');

      await ok(tester);
      expect(watched, [false]);
      expect(c.clips.muted, isTrue);
    });

    testWidgets('≡ and On TV mode change it: the label follows the sound', (tester) async {
      await showTv(tester);
      await press(tester, LogicalKeyboardKey.contextMenu);
      expect(soundOnBadge, findsOneWidget);
      expect(find.descendant(of: soundOnBadge, matching: find.text(t.reel.card.mute)), findsOneWidget);

      ReelScreen.remoteAction('mute');
      await settle(tester);
      expect(c.clips.muted, isTrue);
      expect(soundOff, findsOneWidget);
      expect(soundOnBadge, findsNothing);

      ReelScreen.remoteAction('volumeUp');
      await settle(tester);
      expect(soundOnBadge, findsOneWidget);
    });

    testWidgets('a tap (a mouse in TV mode) toggles it', (tester) async {
      await showTv(tester);
      await tester.tap(soundOff);
      await settle(tester);
      expect(c.clips.muted, isFalse);
      await tester.tap(soundOnBadge);
      await settle(tester);
      expect(c.clips.muted, isTrue);
      expect(watched, isEmpty);
    });
  });

  // Apple TV runs Back on its key down; an Android TV (a Shield) on its
  // key up ([handleBackKeyAction]). Both take the same d-pad paths.
  for (final appleTv in [true, false]) {
    group('with the d-pad (${appleTv ? 'Apple TV' : 'Android TV'})', () {
      setUp(() {
        if (appleTv) return;
        TvDetectionService.debugSetAppleTVOverride(null);
        TvDetectionService.debugSetTvOverride(true);
      });

      testWidgets('Back on the card focuses it; OK turns the sound on, OK again mutes', (tester) async {
        await showTv(tester);
        expect(await tester.sendKeyEvent(LogicalKeyboardKey.escape), isTrue, reason: 'the Reel takes this Back');
        await settle(tester);
        expect(ring, findsOneWidget);
        expect((c.deck.id, title()), ('a', 'Harbor Lights'));
        expect(find.descendant(of: soundOff, matching: find.text('  ·  ${t.reel.card.soundButtonOk}')), findsOneWidget);

        await ok(tester);
        expect(c.clips.muted, isFalse);
        expect(settings.read(SettingsService.reelMuted), isFalse);
        expect(soundOnBadge, findsOneWidget);
        expect(find.text(t.reel.card.mute), findsOneWidget);
        expect(ring, findsOneWidget, reason: 'the button keeps the focus');
        expect(watched, isEmpty, reason: 'OK on the button is not Watch');
        expect(find.text(t.reel.sheet.details), findsNothing);

        await ok(tester);
        expect(c.clips.muted, isTrue);
        expect(settings.read(SettingsService.reelMuted), isTrue);
        expect(soundOff, findsOneWidget);
      });

      testWidgets('on the button ↓ ← → move nothing; ↑ goes back to the card on the same title', (tester) async {
        await showTv(tester);
        await press(tester, LogicalKeyboardKey.escape);
        expect(ring, findsOneWidget);

        for (final k in [LogicalKeyboardKey.arrowDown, LogicalKeyboardKey.arrowLeft, LogicalKeyboardKey.arrowRight]) {
          expect(await tester.sendKeyEvent(k), isTrue);
          await settle(tester);
          expect((c.deck.id, title()), ('a', 'Harbor Lights'), reason: '$k moved nothing');
          expect(ring, findsOneWidget);
        }

        await press(tester, LogicalKeyboardKey.arrowUp);
        expect(ring, findsNothing);
        expect((c.deck.id, title()), ('a', 'Harbor Lights'));

        // The card has the keys again.
        await press(tester, LogicalKeyboardKey.arrowDown);
        expect(title(), 'Lantern Bay');
      });

      testWidgets('Back on the button goes on to the shell and lets the focus go', (tester) async {
        await showTv(tester);
        await press(tester, LogicalKeyboardKey.escape);
        expect(ring, findsOneWidget);
        expect(await tester.sendKeyEvent(LogicalKeyboardKey.escape), isFalse, reason: 'Back belongs to the shell');
        await settle(tester);
        expect(ring, findsNothing);
      });

      testWidgets('≡ on the button does what it does on the card', (tester) async {
        await showTv(tester);
        await press(tester, LogicalKeyboardKey.escape);
        await press(tester, LogicalKeyboardKey.contextMenu);
        expect(c.clips.muted, isFalse);
        expect(soundOnBadge, findsOneWidget);
      });

      testWidgets('the Reel losing focus lets the button go', (tester) async {
        await showTv(tester);
        await press(tester, LogicalKeyboardKey.escape);
        expect(ring, findsOneWidget);
        // A page over it, the sheet or the rail takes the focus.
        FocusManager.instance.primaryFocus!.unfocus();
        await settle(tester);
        expect(ring, findsNothing);
      });

      testWidgets('a Back key up whose press the card never saw goes on', (tester) async {
        await showTv(tester);
        // A sheet or page that closed on the press: only its key up comes.
        expect(await tester.sendKeyUpEvent(LogicalKeyboardKey.escape), isFalse);
        await settle(tester);
        expect(ring, findsNothing);
        await ok(tester);
        expect(watched, [false], reason: 'OK on the card still watches');
      });

      testWidgets('stray Back from the pop that showed the Reel again goes on to the shell', (tester) async {
        final reel = await showTv(tester);
        reel.onTabHidden();
        await settle(tester);
        reel.focusActiveTabIfReady();
        await tester.pump();
        // The player (or a page) popped: the shell shows the tab again, and on
        // an Android TV the pop's Back key events come after it.
        reel.onTabShown();
        expect(await tester.sendKeyDownEvent(LogicalKeyboardKey.escape), isFalse);
        expect(await tester.sendKeyUpEvent(LogicalKeyboardKey.escape), isFalse);
        await settle(tester);
        expect(ring, findsNothing);
        await ok(tester);
        expect(watched, [false], reason: 'OK on the card still watches');

        // The next real Back is the card's again.
        reel.focusActiveTabIfReady();
        await tester.pump();
        await press(tester, LogicalKeyboardKey.escape);
        expect(ring, findsOneWidget);
      });

      if (!appleTv) {
        testWidgets('Android TV: the button comes in on the key up; Back on it goes on, down and up', (tester) async {
          await showTv(tester);
          expect(await tester.sendKeyDownEvent(LogicalKeyboardKey.escape), isTrue);
          await settle(tester);
          expect(ring, findsNothing, reason: 'not on the press');
          expect(await tester.sendKeyUpEvent(LogicalKeyboardKey.escape), isTrue);
          await settle(tester);
          expect(ring, findsOneWidget);

          expect(await tester.sendKeyDownEvent(LogicalKeyboardKey.escape), isFalse);
          await settle(tester);
          expect(ring, findsOneWidget, reason: 'it lets go on the key up');
          expect(await tester.sendKeyUpEvent(LogicalKeyboardKey.escape), isFalse);
          await settle(tester);
          expect(ring, findsNothing);
        });
      }
    });
  }

  group('every visit that starts muted again shows it', () {
    testWidgets('the tab hidden and shown again: muted, "Sound on", not focused', (tester) async {
      final reel = await showTv(tester);
      await press(tester, LogicalKeyboardKey.escape);
      await ok(tester);
      expect(c.clips.muted, isFalse);
      expect(soundOnBadge, findsOneWidget);

      reel.onTabHidden();
      await settle(tester);
      await again(tester, reel);
      expect(c.clips.muted, isTrue);
      expect(soundOff, findsOneWidget);
      expect(ring, findsNothing);
    });
  });

  group('quiet mode', () {
    testWidgets('muted, it stays; with the sound on, it fades with the chrome unless focused', (tester) async {
      await showTv(tester);
      engines.last.firstFrameCtl.add(null);
      await tester.pump(const Duration(seconds: 8));
      await tester.pumpAndSettle();
      expect(soundOff, findsOneWidget);
      expect(opacity(tester), 1);

      await press(tester, LogicalKeyboardKey.contextMenu);
      expect(opacity(tester), 1, reason: 'the key brought the chrome back');
      await tester.pump(const Duration(seconds: 8));
      await tester.pumpAndSettle();
      expect(opacity(tester), 0);

      await press(tester, LogicalKeyboardKey.escape);
      expect(opacity(tester), 1);
      await tester.pump(const Duration(seconds: 8));
      await tester.pumpAndSettle();
      expect(opacity(tester), 1, reason: 'focused, it stays');
    });
  });
}
