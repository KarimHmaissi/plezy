import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/reel/reel_playback_profile.dart';
import 'package:plezy/services/reel_app.dart';
import 'package:plezy/services/settings_service.dart' show ReelCellular;

/// The TMDB rung (V2-63) reads the link from the playback profile, the same
/// source the controller's data budget reads (Wave A leftover), so the two
/// never disagree while the network changes.
void main() {
  const wifi = ReelPlaybackProfile(screen: ReelScreen.compactPortrait, maxHeight: 1080);
  const mobile = ReelPlaybackProfile(screen: ReelScreen.compactPortrait, maxHeight: 1080, link: ReelLink.cellular);

  bool mayRun(ReelPlaybackProfile profile, ReelCellular cellular, {bool key = true}) =>
      ReelApp.tmdbRungMayRun(mayHaveKey: key, profile: profile, cellular: cellular);

  test('off Wi-Fi the profile\'s mobile-data link turns the rung off on Data saver and Stills only', () {
    expect(mayRun(mobile, ReelCellular.dataSaver), isFalse);
    expect(mayRun(mobile, ReelCellular.stillsOnly), isFalse);
    expect(mayRun(mobile, ReelCellular.normal), isTrue);
  });

  test('on Wi-Fi the rung runs whatever the mobile-data pref says', () {
    for (final pref in ReelCellular.values) {
      expect(mayRun(wifi, pref), isTrue, reason: pref.name);
    }
  });

  test('an offline link is not mobile data', () {
    const offline = ReelPlaybackProfile(screen: ReelScreen.compactPortrait, maxHeight: 1080, link: ReelLink.offline);
    expect(mayRun(offline, ReelCellular.dataSaver), isTrue);
  });

  test('no key, no rung', () {
    expect(mayRun(wifi, ReelCellular.normal, key: false), isFalse);
  });
}
