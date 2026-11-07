import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/fork_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/screens/reel/reel_intro.dart';
import 'package:plezy/screens/reel/reel_screen.dart';
import 'package:plezy/services/customisation/customisation_store.dart';
import 'package:plezy/services/reel/clip_filter.dart';
import 'package:plezy/services/reel/clip_player.dart';
import 'package:plezy/services/reel/clip_resolver.dart';
import 'package:plezy/services/reel/reel_controller.dart';
import 'package:plezy/services/reel/reel_decks.dart';
import 'package:plezy/services/reel/reel_library.dart';
import 'package:plezy/services/reel/reel_store.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/platform_detector.dart';

import '../test_helpers/prefs.dart';
import 'clip_player_test.dart' show FakeClipEngine;

class _Servers implements ReelServers {
  @override
  Future<List<PlexExtraClip>> extras(String serverId, String ratingKey, {required Duration timeout}) async => [];

  @override
  String? clipUrl(String serverId, String partKey) => null;
}

class _Media implements ReelMedia {
  @override
  Future<MediaItem?> item(String serverId, String ratingKey) async => null;

  @override
  Future<MediaItem?> fullItem(String serverId, String ratingKey) => item(serverId, ratingKey);

  @override
  String? imageUrl(String serverId, String? path, {required int width}) => null;
}

/// A deck with nothing in it: the Reel shows its own message, so nothing
/// opens a player in these tests.
class _EmptyDeck extends ReelDeck {
  @override
  String get id => 'harbor';
  @override
  String get name => 'Harbor Lights and friends';
  @override
  bool get keepsSeen => true;
  @override
  bool get raw => true;
  @override
  Future<List<ReelCardData>> load() async => const [];
}

void main() {
  final s = t.reel.intro;

  setUp(() => LocaleSettings.setLocaleSync(AppLocale.en));

  group('ReelIntro', () {
    Future<void> pump(WidgetTester tester, {required bool tv, required VoidCallback onStart}) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = tv ? const Size(1920, 1080) : const Size(420, 860);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: monoTheme(MonoPalette.dark),
          home: Scaffold(
            body: ReelIntro(tv: tv, onStart: onStart),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('phone: what the Reel is, the phone gestures, and Start', (tester) async {
      var started = 0;
      await pump(tester, tv: false, onStart: () => started++);

      expect(find.text(s.title), findsOneWidget);
      expect(find.text(s.bodyPhone), findsOneWidget);
      expect(find.text(s.bodyTv), findsNothing);
      await tester.tap(find.text(s.start));
      expect(started, 1);
    });

    testWidgets('TV: the remote keys, and the button never takes focus from the Reel', (tester) async {
      await pump(tester, tv: true, onStart: () {});

      expect(find.text(s.bodyTv), findsOneWidget);
      expect(find.text(s.bodyPhone), findsNothing);
      final button = find.ancestor(of: find.text(s.start), matching: find.byType(FilledButton));
      expect(Focus.of(tester.element(button)).canRequestFocus, isFalse);
    });
  });

  group('ReelScreen first run', () {
    late ForkDatabase db;
    late ReelStore store;
    late ReelController c;
    late SettingsService settings;
    late int created;
    final key = GlobalKey<ReelScreenState>();

    setUp(() async {
      resetSharedPreferencesForTest();
      SettingsService.resetForTesting();
      settings = await SettingsService.getInstance();
      db = ForkDatabase.memory();
      final custom = LocalCustomisationStore(db);
      store = ReelStore(database: () async => db, settings: () async => custom);
      created = 0;
      c = ReelController(
        decks: [_EmptyDeck()],
        resolver: ClipResolver(
          servers: _Servers(),
          store: store,
          aniList: (_) async => null,
          animeThemes: (_) async => const {},
        ),
        clips: ClipPlayer(engine: FakeClipEngine.new),
        store: store,
        media: _Media(),
        onWatch: (_, {required onTv}) async => true,
        addToWatchlist: (_) async => true,
        externalClips: true,
      );
    });

    tearDown(() async {
      ReelScreen.debugIntroDeferred = false;
      TvDetectionService.debugSetAppleTVOverride(null);
      await db.close();
    });

    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
    }

    /// The Reel tab, shown by the shell.
    Future<ReelScreenState> show(WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(420, 860);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: monoTheme(MonoPalette.dark),
          home: Scaffold(
            body: ReelScreen(
              key: key,
              create: (_) async {
                created++;
                return c;
              },
            ),
          ),
        ),
      );
      final state = key.currentState!..onTabShown();
      await settle(tester);
      return state;
    }

    Future<int> events() async => (await store.events(since: DateTime.utc(2000))).length;

    testWidgets('the first open shows the intro in place of the feed, and the Reel waits', (tester) async {
      await show(tester);

      expect(find.byType(ReelIntro), findsOneWidget);
      expect(created, 1, reason: 'the session is built behind the intro');
      expect(c.active, isFalse, reason: 'nothing plays or is recorded under the intro');
      expect(await tester.runAsync(events), 0);
    });

    testWidgets('Start dismisses it for good on this device and starts the Reel', (tester) async {
      await show(tester);
      await tester.tap(find.text(s.start));
      await settle(tester);

      expect(find.byType(ReelIntro), findsNothing);
      expect(settings.read(SettingsService.reelIntroSeen), isTrue);
      expect(c.active, isTrue);
      expect(find.text(t.reel.card.emptyTitle(deck: 'Harbor Lights and friends')), findsOneWidget);
    });

    testWidgets('once seen, the Reel opens straight on its deck', (tester) async {
      await settings.write(SettingsService.reelIntroSeen, true);
      await show(tester);

      expect(find.byType(ReelIntro), findsNothing);
      expect(c.active, isTrue);
    });

    testWidgets('TV: a fresh OK press starts the Reel; the d-pad stays on the intro', (tester) async {
      TvDetectionService.debugSetAppleTVOverride(true);
      final state = await show(tester);
      state.focusActiveTabIfReady();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await settle(tester);
      expect(find.byType(ReelIntro), findsOneWidget);
      expect(c.active, isFalse);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
      await settle(tester);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      await settle(tester);
      expect(find.byType(ReelIntro), findsNothing);
      expect(settings.read(SettingsService.reelIntroSeen), isTrue);
      expect(c.active, isTrue);
    });

    testWidgets('an open from the phone\'s On TV mode lets the Reel start without it', (tester) async {
      await show(tester);
      expect(find.byType(ReelIntro), findsOneWidget);

      ReelScreen.debugIntroDeferred = true;
      ReelScreen.requestedDeck.value = '';
      await settle(tester);

      expect(find.byType(ReelIntro), findsNothing);
      expect(c.active, isTrue);
      expect(settings.read(SettingsService.reelIntroSeen), isFalse, reason: 'it shows on the next launch');
    });
  });
}
