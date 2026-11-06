import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/device_performance.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/widgets/tv_spotlight_background.dart';

import '../test_helpers/prefs.dart';

/// The Reel's spotlight fade (V2-32): the artwork leaves for the clip
/// through the app's reduce-motion and effects-tier gates.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    TvDetectionService.debugSetAppleTVOverride(true);
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  tearDown(() {
    TvDetectionService.debugSetAppleTVOverride(null);
    DevicePerformance.debugReset();
  });

  Future<Duration> fade(WidgetTester tester) async {
    await SettingsService.getInstance();
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      TranslationProvider(
        child: const MaterialApp(
          home: Scaffold(
            body: SizedBox.expand(
              child: TvSpotlightBackground(
                item: MediaItem.plex(id: 'movie_1', kind: MediaKind.movie, title: 'Harbor Lights'),
                client: null,
                allowNetwork: false,
                showArtwork: false,
                contentTop: 80,
                contentBottom: 200,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final artwork = tester.widget<AnimatedOpacity>(
      find.byWidgetPredicate((w) => w is AnimatedOpacity && w.opacity == 0).first,
    );
    return artwork.duration;
  }

  testWidgets('at full motion the artwork fades out', (tester) async {
    expect(await fade(tester), greaterThan(Duration.zero));
  });

  testWidgets('with reduce motion on the artwork goes at once', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    expect(await fade(tester), Duration.zero);
  });

  testWidgets('on the reduced effects tier the artwork goes at once', (tester) async {
    DevicePerformance.debugReset(autoReduced: true);
    expect(await fade(tester), Duration.zero);
  });
}
