import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Size;
import 'package:plezy/services/reel/reel_playback_profile.dart';

/// A playback profile driven by a test's link switch: the large-screen
/// rule on mobile data while [metered] says so, else on Wi-Fi. [changed]
/// firing is the network changing. The Reel reads its link only from the
/// profile (the controller's data budget included), as the app does. While
/// [offline] says so there is no network at all (V2-15).
class FakeLinkProfile extends ChangeNotifier implements ValueListenable<ReelPlaybackProfile> {
  FakeLinkProfile(this.metered, [this.changed, this.offline]) {
    changed?.addListener(notifyListeners);
  }

  final bool Function() metered;
  final Listenable? changed;
  final bool Function()? offline;

  @override
  ReelPlaybackProfile get value => ReelPlaybackProfile.from(
    tv: false,
    size: Size.zero,
    devicePixelRatio: 1,
    link: (offline?.call() ?? false)
        ? ReelLink.offline
        : metered()
        ? ReelLink.cellular
        : ReelLink.unmetered,
  );

  @override
  void dispose() {
    changed?.removeListener(notifyListeners);
    super.dispose();
  }
}
