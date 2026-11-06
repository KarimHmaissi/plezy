import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/screens/settings/reel_settings_screen.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';

import '../../test_helpers/prefs.dart';

void main() {
  late SettingsService settings;

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    settings = await SettingsService.getInstance();
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  Future<void> pump(WidgetTester tester, {required bool tv}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 2400);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(
        theme: monoTheme(MonoPalette.dark),
        home: ReelSettingsScreen(tv: tv),
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
    expect(find.text(s.cellularNormal), findsOneWidget);
    expect(find.text(s.captions), findsOneWidget);
    expect(find.text(s.showTab), findsOneWidget);
    expect(find.text(s.okAction), findsNothing, reason: 'the OK button is the TV remote');
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

  test('every choice has its own label', () {
    expect(ReelStartSound.values.map(ReelSettingsScreen.startSoundLabel).toSet(), hasLength(2));
    expect(ReelClipEnd.values.map(ReelSettingsScreen.clipEndLabel).toSet(), hasLength(3));
    expect(ReelCellular.values.map(ReelSettingsScreen.cellularLabel).toSet(), hasLength(3));
  });
}
