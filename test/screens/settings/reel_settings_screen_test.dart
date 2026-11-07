import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/screens/settings/reel_clip_cache_tile.dart';
import 'package:plezy/screens/settings/reel_settings_screen.dart';
import 'package:plezy/services/reel/reel_clip_cache.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';

import '../../test_helpers/prefs.dart';

/// The clip disk cache (V2-10), holding [bytes] of [capBytes].
class _FakeClipCache extends ReelClipCache {
  _FakeClipCache({this.bytes = 0, this.fails = false}) : super(supported: true);

  int bytes;
  final int capBytes = 192 * 1024 * 1024;
  final bool fails;
  int clears = 0;

  @override
  Future<ReelClipCacheUsage?> usage() async => ReelClipCacheUsage(bytes: bytes, capBytes: capBytes);

  @override
  Future<int?> clear() async {
    clears++;
    if (fails) return null;
    final freed = bytes;
    bytes = 0;
    return freed;
  }
}

void main() {
  late SettingsService settings;

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    settings = await SettingsService.getInstance();
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  Future<void> pump(WidgetTester tester, {required bool tv, bool debugBuild = false, ReelClipCache? clipCache}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 2400);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(
        theme: monoTheme(MonoPalette.dark),
        home: ReelSettingsScreen(tv: tv, debugBuild: debugBuild, clipCache: clipCache ?? _FakeClipCache()),
      ),
    );
    await tester.pumpAndSettle();
  }

  final s = t.reel.settings;

  testWidgets('phone: sound, clip end, mobile data, captions and the tab, with today\'s choices', (tester) async {
    await pump(tester, tv: false);

    expect(find.text(s.title), findsOneWidget);
    expect(find.text(s.startSound), findsOneWidget);
    expect(find.text(s.startSoundOn), findsOneWidget);
    expect(find.text(s.clipEnd), findsOneWidget);
    expect(find.text(s.clipEndTwiceThenHold), findsOneWidget);
    expect(find.text(s.cellular), findsOneWidget);
    expect(find.text(s.cellularDataSaverSubtitle), findsOneWidget, reason: 'Data saver by default, with its trade');
    expect(find.text(s.captions), findsOneWidget);
    expect(find.text(s.showTab), findsOneWidget);
    expect(find.text(s.okAction), findsNothing, reason: 'the OK button is the TV remote');
  });

  testWidgets("both devices have For You's own words and today's rebuild (V2-51)", (tester) async {
    for (final tv in [false, true]) {
      await pump(tester, tv: tv);
      expect(find.text(t.reelForYou.title), findsOneWidget, reason: 'the group header');
      expect(find.text(t.reelForYou.explainer), findsOneWidget);
      expect(find.text(t.reelForYou.note), findsOneWidget);
      expect(find.text(t.reelForYou.rebuild), findsOneWidget);
    }
  });

  testWidgets('both devices have a way to the Decks screen', (tester) async {
    for (final tv in [false, true]) {
      await pump(tester, tv: tv);
      expect(find.text(t.reel.decks.subtitle), findsOneWidget);
    }
  });

  testWidgets('TV: the OK button instead of mobile data', (tester) async {
    await pump(tester, tv: true);

    expect(find.text(s.okAction), findsOneWidget);
    expect(find.text(s.cellular), findsNothing);
    expect(find.text(s.startSound), findsOneWidget);
    expect(find.text(s.clipEnd), findsOneWidget);
    expect(find.text(s.showTab), findsOneWidget);
  });

  group('sound when a card starts', () {
    Future<void> openSound(WidgetTester tester) async {
      await tester.tap(find.text(s.startSound));
      await tester.pumpAndSettle();
    }

    testWidgets('TV: Start muted or With sound, on its own pref; muted if other audio is the phone\'s', (tester) async {
      // A "With sound" an older build stored under the phone's pref.
      await settings.write(SettingsService.reelStartSound, ReelStartSound.sound);
      await pump(tester, tv: true);
      expect(find.text(s.startSoundMuted), findsOneWidget, reason: 'the TV starts muted, whatever that pref holds');
      await openSound(tester);

      expect(find.text(s.startSoundMuted), findsWidgets);
      expect(find.text(s.startSoundMutedDescription), findsOneWidget);
      expect(find.text(s.startSoundOn), findsOneWidget);
      expect(find.text(s.startSoundMutedIfOtherAudio), findsNothing, reason: 'the TV can\'t tell other audio apart');

      await tester.tap(find.text(s.startSoundOn));
      await tester.pumpAndSettle();
      expect(settings.read(SettingsService.reelTvStartSound), ReelStartSound.sound);
      expect(find.text(s.startSoundOn), findsOneWidget, reason: 'the row\'s subtitle follows the pick');
    });

    testWidgets('phone: as before, With sound or muted if other audio, on its own pref', (tester) async {
      await pump(tester, tv: false);
      expect(find.text(s.startSoundOn), findsOneWidget, reason: 'the phone starts with sound');
      await openSound(tester);

      expect(find.text(s.startSoundMuted), findsNothing);
      await tester.tap(find.text(s.startSoundMutedIfOtherAudio));
      await tester.pumpAndSettle();

      expect(settings.read(SettingsService.reelStartSound), ReelStartSound.mutedIfOtherAudio);
      expect(settings.read(SettingsService.reelTvStartSound), ReelStartSound.muted, reason: 'the TV\'s is its own');
    });
  });

  testWidgets('a clip-end pick is stored and shown at once', (tester) async {
    await pump(tester, tv: false);

    await tester.tap(find.text(s.clipEnd));
    await tester.pumpAndSettle();
    await tester.tap(find.text(s.clipEndNextCard).last);
    await tester.pumpAndSettle();

    expect(settings.read(SettingsService.reelClipEnd), ReelClipEnd.nextCard);
    expect(find.text(s.clipEndNextCard), findsOneWidget, reason: 'the row\'s subtitle follows the pick');
  });

  testWidgets('mobile data offers each choice with its trade', (tester) async {
    await pump(tester, tv: false);

    await tester.tap(find.text(s.cellular));
    await tester.pumpAndSettle();
    expect(find.text(s.cellularDataSaverDescription), findsOneWidget);
    expect(find.text(s.cellularStillsOnlyDescription), findsOneWidget);
    await tester.tap(find.text(s.cellularStillsOnly));
    await tester.pumpAndSettle();

    expect(settings.read(SettingsService.reelCellular), ReelCellular.stillsOnly);
    expect(find.text(s.cellularStillsOnly), findsOneWidget, reason: 'the row\'s subtitle follows the pick');
    expect(find.text(s.cellularDataSaverSubtitle), findsNothing);
  });

  testWidgets('TV: OK can open Details', (tester) async {
    await pump(tester, tv: true);

    await tester.tap(find.text(s.okActionDetails));
    await tester.pumpAndSettle();

    expect(settings.read(SettingsService.reelOkAction), ReelOkAction.details);
  });

  testWidgets('switches write their prefs; the tab toggle starts on', (tester) async {
    await pump(tester, tv: false);

    final tab = find.widgetWithText(SwitchListTile, s.showTab);
    expect(tester.widget<SwitchListTile>(tab).value, isTrue);
    await tester.tap(tab);
    await tester.pumpAndSettle();
    expect(settings.read(SettingsService.showReelTab), isFalse);
    expect(tester.widget<SwitchListTile>(tab).value, isFalse);

    await tester.tap(find.widgetWithText(SwitchListTile, s.captions));
    await tester.pumpAndSettle();
    expect(settings.read(SettingsService.reelCaptions), isTrue);
  });

  group('hidden developer setting (V2-62)', () {
    testWidgets('a release build hides it until debug logging is on', (tester) async {
      for (final tv in [false, true]) {
        await pump(tester, tv: tv);
        expect(find.text(s.developer), findsNothing);
        expect(find.text(s.developerTools), findsNothing);
      }

      await settings.write(SettingsService.enableDebugLogging, true);
      for (final tv in [false, true]) {
        await pump(tester, tv: tv);
        expect(find.text(s.developerTools), findsOneWidget, reason: 'both devices, tv: $tv');
      }
    });

    testWidgets('a debug build always shows it', (tester) async {
      await pump(tester, tv: false, debugBuild: true);
      expect(find.text(s.developerTools), findsOneWidget);
    });

    testWidgets('it starts off and its switch writes the overlay pref', (tester) async {
      await settings.write(SettingsService.enableDebugLogging, true);
      await pump(tester, tv: true);

      final tile = find.widgetWithText(SwitchListTile, s.developerTools);
      await tester.scrollUntilVisible(tile, 200);
      expect(tester.widget<SwitchListTile>(tile).value, isFalse);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(settings.read(SettingsService.reelDebugOverlay), isTrue);
    });
  });

  group('clip loudness switch (V2-19, D9)', () {
    testWidgets('the TV shows it in the developer group, off; the phone never does', (tester) async {
      await pump(tester, tv: true);
      expect(find.text(s.clipNormalization), findsNothing, reason: 'hidden with the developer group');

      await settings.write(SettingsService.enableDebugLogging, true);
      await pump(tester, tv: false);
      expect(find.text(s.developerTools), findsOneWidget);
      expect(find.text(s.clipNormalization), findsNothing, reason: 'the phone feed has its own players');

      await pump(tester, tv: true);
      final tile = find.widgetWithText(SwitchListTile, s.clipNormalization);
      await tester.scrollUntilVisible(tile, 200);
      expect(tester.widget<SwitchListTile>(tile).value, isFalse);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(settings.read(SettingsService.reelClipNormalization), isTrue);
      expect(settings.read(SettingsService.reelDebugOverlay), isFalse, reason: 'its own pref');
    });
  });

  test('every choice has its own label', () {
    expect(ReelStartSound.values.map(ReelSettingsScreen.startSoundLabel).toSet(), hasLength(3));
    expect(ReelClipEnd.values.map(ReelSettingsScreen.clipEndLabel).toSet(), hasLength(3));
    expect(ReelCellular.values.map(ReelSettingsScreen.cellularLabel).toSet(), hasLength(3));
    expect(ReelCellular.values.map(ReelSettingsScreen.cellularSubtitle).toSet(), hasLength(3));
  });

  group('Clear Reel cache (V2-10)', () {
    const mib = 1024 * 1024;

    testWidgets('the TV shows how full the clip cache is; the phone has no row', (tester) async {
      await pump(tester, tv: true, clipCache: _FakeClipCache(bytes: 84 * mib));
      expect(find.text(s.storage), findsOneWidget);
      expect(find.text(s.clearCache), findsOneWidget);
      expect(find.text('84.0 MB of 192 MB on this device'), findsOneWidget);

      await pump(tester, tv: false, clipCache: _FakeClipCache(bytes: 84 * mib));
      expect(find.text(s.clearCache), findsNothing, reason: "the phone's feed never writes the clip cache");
    });

    testWidgets('a device without the cache has no row', (tester) async {
      await pump(tester, tv: true, clipCache: ReelClipCache(supported: false));
      expect(find.text(s.clearCache), findsNothing);
    });

    testWidgets('a tap asks first, then clears and says so', (tester) async {
      final cache = _FakeClipCache(bytes: 84 * mib);
      await pump(tester, tv: true, clipCache: cache);
      await tester.tap(find.text(s.clearCache));
      await tester.pumpAndSettle();
      expect(find.text(s.clearCacheConfirm), findsOneWidget);
      expect(cache.clears, 0, reason: 'nothing is removed before the confirm');

      await tester.tap(find.text(t.common.clear));
      await tester.pumpAndSettle();
      expect(cache.clears, 1);
      expect(find.text(s.clearCacheDone), findsOneWidget);
      expect(find.text('0 B of 192 MB on this device'), findsOneWidget);
    });

    testWidgets('cancel keeps the cache', (tester) async {
      final cache = _FakeClipCache(bytes: 84 * mib);
      await pump(tester, tv: true, clipCache: cache);
      await tester.tap(find.text(s.clearCache));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.common.cancel));
      await tester.pumpAndSettle();
      expect(cache.clears, 0);
      expect(find.text('84.0 MB of 192 MB on this device'), findsOneWidget);
    });

    testWidgets('a failed clear says so', (tester) async {
      await pump(tester, tv: true, clipCache: _FakeClipCache(bytes: 84 * mib, fails: true));
      await tester.tap(find.text(s.clearCache));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.common.clear));
      await tester.pumpAndSettle();
      expect(find.text(s.clearCacheFailed), findsOneWidget);
    });

    test('with no usage, or no room for a cache, the row says what it does', () {
      expect(ReelClipCacheTile.subtitleFor(null), s.clearCacheDescription);
      expect(ReelClipCacheTile.subtitleFor(const ReelClipCacheUsage(bytes: 0, capBytes: 0)), s.clearCacheDescription);
    });
  });
}
