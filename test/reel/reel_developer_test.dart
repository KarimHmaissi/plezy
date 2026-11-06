import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/deep_links/deep_link.dart';
import 'package:plezy/services/reel/reel_developer.dart';
import 'package:plezy/services/settings_service.dart';

import '../test_helpers/prefs.dart';

/// V2-62: the measure-day probe and the debug overlay run only in a debug
/// build or with the hidden developer setting on; in a release build any
/// other `plezy://reel?probe=…` link just opens the Reel.
void main() {
  late SettingsService settings;

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    settings = await SettingsService.getInstance();
  });

  ReelProbeKind? releaseProbe(String? name) => ReelDeveloper.probe(name, debugBuild: false, settings: settings);

  group('release build', () {
    test('by default a probe link opens the Reel instead', () {
      expect(releaseProbe('coverage'), isNull);
      expect(releaseProbe('watchstate'), isNull);
      expect(ReelDeveloper.on(debugBuild: false, settings: settings), isFalse);
      expect(ReelDeveloper.visible(debugBuild: false, settings: settings), isFalse);
    });

    test('the setting alone is not enough: its row is hidden until debug logging is on', () async {
      await settings.write(SettingsService.reelDebugOverlay, true);
      expect(releaseProbe('coverage'), isNull);
      expect(ReelDeveloper.on(debugBuild: false, settings: settings), isFalse);

      await settings.write(SettingsService.enableDebugLogging, true);
      expect(ReelDeveloper.visible(debugBuild: false, settings: settings), isTrue);
      expect(ReelDeveloper.on(debugBuild: false, settings: settings), isTrue);
      expect(releaseProbe('coverage'), ReelProbeKind.coverage);
      expect(releaseProbe('watchstate'), ReelProbeKind.watchstate);
    });

    test('debug logging alone shows the row but switches nothing on', () async {
      await settings.write(SettingsService.enableDebugLogging, true);
      expect(ReelDeveloper.visible(debugBuild: false, settings: settings), isTrue);
      expect(ReelDeveloper.on(debugBuild: false, settings: settings), isFalse);
      expect(releaseProbe('coverage'), isNull);
    });

    test('turning debug logging off turns the tools off with it', () async {
      await settings.write(SettingsService.reelDebugOverlay, true);
      await settings.write(SettingsService.enableDebugLogging, true);
      await settings.write(SettingsService.enableDebugLogging, false);
      expect(ReelDeveloper.on(debugBuild: false, settings: settings), isFalse);
      expect(releaseProbe('coverage'), isNull);
    });
  });

  test('a debug build runs a known probe without the setting', () {
    expect(ReelDeveloper.probe('coverage', debugBuild: true, settings: settings), ReelProbeKind.coverage);
    expect(ReelDeveloper.visible(debugBuild: true, settings: settings), isTrue);
    expect(ReelDeveloper.on(debugBuild: true, settings: settings), isFalse, reason: 'the overlay waits for the toggle');
  });

  test('the extras-shape probe (V2-20) is gated like the others, by its link name', () async {
    expect(releaseProbe('extras-shape'), isNull);
    expect(ReelDeveloper.probe('extras-shape', debugBuild: true, settings: settings), ReelProbeKind.extrasShape);
    await settings.write(SettingsService.reelDebugOverlay, true);
    await settings.write(SettingsService.enableDebugLogging, true);
    expect(releaseProbe('extras-shape'), ReelProbeKind.extrasShape);
    expect(releaseProbe('extrasShape'), isNull, reason: 'the link name, not the Dart name');
    expect(
      DeepLink.tryParse('plezy://reel?probe=extras-shape'),
      isA<ReelLink>().having((l) => l.probe, 'probe', 'extras-shape'),
    );
  });

  test('no probe, or one nobody knows, never runs anything', () async {
    await settings.write(SettingsService.reelDebugOverlay, true);
    await settings.write(SettingsService.enableDebugLogging, true);
    for (final debugBuild in [false, true]) {
      expect(ReelDeveloper.probe(null, debugBuild: debugBuild, settings: settings), isNull);
      expect(ReelDeveloper.probe('crawl', debugBuild: debugBuild, settings: settings), isNull);
      expect(ReelDeveloper.probe('', debugBuild: debugBuild, settings: settings), isNull);
    }
  });

  test('without settings nothing is on', () {
    SettingsService.resetForTesting();
    expect(ReelDeveloper.on(debugBuild: false), isFalse);
    expect(ReelDeveloper.probe('coverage', debugBuild: false), isNull);
  });

  test('the link still carries the probe and the deck, so the launcher can choose', () {
    final link = DeepLink.tryParse('plezy://reel?deck=for-you&probe=coverage');
    expect(link, isA<ReelLink>().having((l) => l.probe, 'probe', 'coverage').having((l) => l.deck, 'deck', 'for-you'));
  });
}
