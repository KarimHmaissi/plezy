import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/utils/platform_detector.dart';

import '../test_helpers/prefs.dart';

void main() {
  setUp(() {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
  });

  tearDown(() => PlatformDetector.debugSetIsAndroidTVOverride(null));

  group('matchContentFrameRate default', () {
    test('is on for a fresh install on Android TV', () async {
      PlatformDetector.debugSetIsAndroidTVOverride(true);
      final settings = await SettingsService.getInstance();

      expect(settings.read(SettingsService.matchContentFrameRate), isTrue);
    });

    test('is off on a phone', () async {
      PlatformDetector.debugSetIsAndroidTVOverride(false);
      final settings = await SettingsService.getInstance();

      expect(settings.read(SettingsService.matchContentFrameRate), isFalse);
    });

    test('a value saved on the TV still wins over the default', () async {
      PlatformDetector.debugSetIsAndroidTVOverride(true);
      final settings = await SettingsService.getInstance();
      await settings.write(SettingsService.matchContentFrameRate, false);

      expect(settings.read(SettingsService.matchContentFrameRate), isFalse);
    });

    test('a value saved on a phone still wins over the default', () async {
      PlatformDetector.debugSetIsAndroidTVOverride(false);
      final settings = await SettingsService.getInstance();
      await settings.write(SettingsService.matchContentFrameRate, true);

      expect(settings.read(SettingsService.matchContentFrameRate), isTrue);
    });

    test('resolution matching stays off on Android TV', () async {
      PlatformDetector.debugSetIsAndroidTVOverride(true);
      final settings = await SettingsService.getInstance();

      expect(settings.read(SettingsService.matchContentResolution), isFalse);
    });
  });
}
