import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/screens/settings/ai_settings_screen.dart';
import 'package:plezy/services/credential_vault.dart';
import 'package:plezy/services/customisation/customisation_store.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/tmdb/tmdb_key_store.dart';
import 'package:plezy/theme/mono_theme.dart';

import '../../test_helpers/prefs.dart';

/// Shaped like a TMDB v3 API key; not a real one.
const _fakeApiKey = '0123456789abcdef0123456789abcdef';

void main() {
  setUp(() async {
    resetSharedPreferencesForTest();
    CredentialVault.resetKeyForTesting();
    await SettingsService.getInstance();
    LocaleSettings.setLocaleSync(AppLocale.en);
    // Spend and auto-refresh settings live in the customisation store; an
    // in-memory map keeps database work out of the widget test's fake clock.
    Customisation.debugSetStore(_MemoryCustomisationStore());
  });

  tearDown(() => Customisation.debugSetStore(null));

  Future<void> pumpScreen(WidgetTester tester) async {
    // Not a phone: the screen shows this device's own keys, like on the TV.
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 2400);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(MaterialApp(theme: monoTheme(MonoPalette.dark), home: const AiSettingsScreen()));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = null;
  }

  testWidgets('without a TMDB key: paste and receive, no test or remove', (tester) async {
    await pumpScreen(tester);

    expect(find.text('Paste TMDB key'), findsOneWidget);
    expect(find.text('No TMDB key on this device yet'), findsOneWidget);
    expect(find.text('Receive TMDB key from another device'), findsOneWidget);
    expect(find.text('Test TMDB key'), findsNothing);
    expect(find.text('Remove TMDB key'), findsNothing);
    await unmount(tester);
  });

  testWidgets("For You's own words and today's rebuild are no longer on the AI page", (tester) async {
    await pumpScreen(tester);
    expect(find.text("Rebuild today's For You"), findsNothing, reason: "they moved to the Reel's settings (V2-46)");
    expect(find.text('Tell For You in your own words'), findsNothing);
    await unmount(tester);
  });

  testWidgets('with a TMDB key: masked, replace, test and remove', (tester) async {
    await tester.runAsync(() => TmdbKeyStore.write(_fakeApiKey));
    await pumpScreen(tester);

    expect(find.text('Replace TMDB key'), findsOneWidget);
    expect(find.text('TMDB key ••••cdef saved on this device'), findsOneWidget);
    expect(find.textContaining(_fakeApiKey), findsNothing);
    expect(find.text('Test TMDB key'), findsOneWidget);
    expect(find.text('Remove TMDB key'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('remove asks first, then clears the stored key', (tester) async {
    await tester.runAsync(() => TmdbKeyStore.write(_fakeApiKey));
    await pumpScreen(tester);

    await tester.tap(find.text('Remove TMDB key'));
    await tester.pumpAndSettle();
    expect(find.text('Remove the TMDB key?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Remove TMDB key').hitTestable());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();

    expect(await tester.runAsync(TmdbKeyStore.read), isNull);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.text('No TMDB key on this device yet'), findsOneWidget);
    expect(find.text('Remove TMDB key'), findsNothing);
    await unmount(tester);
  });

  testWidgets('the D-pad reaches the TMDB key from the Anthropic key and opens the paste dialog', (tester) async {
    await pumpScreen(tester);

    final tmdbTile = find.byKey(const ValueKey('tmdb-key'));
    bool tmdbFocused() {
      final focused = FocusManager.instance.primaryFocus?.context;
      return focused != null &&
          (focused.widget.key == const ValueKey('tmdb-key') ||
              find.descendant(of: tmdbTile, matching: find.byWidget(focused.widget)).evaluate().isNotEmpty);
    }

    // Anthropic key (autofocused) → Receive key → TMDB key.
    for (var i = 0; i < 4 && !tmdbFocused(); i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
    }
    expect(tmdbFocused(), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('TMDB API key or Read Access Token'), findsOneWidget);
    await unmount(tester);
  });
}

class _MemoryCustomisationStore implements CustomisationStore {
  final Map<String, String> _settings = {};

  @override
  Future<String?> readSetting(String key) async => _settings[key];

  @override
  Future<void> writeSetting(String key, String? value) async =>
      value == null ? _settings.remove(key) : _settings[key] = value;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
