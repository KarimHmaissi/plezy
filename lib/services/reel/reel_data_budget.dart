import '../settings_service.dart' show ReelCellular;
import 'reel_playback_profile.dart' show ReelPlaybackProfile;

/// What the Reel may spend on the link it has (plan V2-53, the
/// `reel_cellular` pref). Off mobile data every choice plays as on Wi-Fi;
/// on a cellular-only link the pref decides:
///
/// * [ReelCellular.normal]: as on Wi-Fi ([full]).
/// * [ReelCellular.dataSaver]: the card on screen and the next one only, so
///   a fast double swipe may land on a still before its clip opens. The
///   lower picture height is the playback profile's
///   ([ReelPlaybackProfile.dataSaverHeight], V2-16), which reads the same
///   pref.
/// * [ReelCellular.stillsOnly]: no clip players at all, each card's art
///   only. The views take the memory ladder's "stills" path for this.
class ReelDataBudget {
  const ReelDataBudget._(this.name, {required this.clips, required this.ahead, required this.behind});

  /// Wi-Fi, or mobile data on Normal: the card on screen, the next two and
  /// the one behind.
  static const full = ReelDataBudget._('full', clips: true, ahead: 2, behind: true);

  /// Mobile data on Data saver: the card on screen and the next one.
  static const saver = ReelDataBudget._('data saver', clips: true, ahead: 1, behind: false);

  /// Mobile data on Stills only.
  static const stills = ReelDataBudget._('stills only', clips: false, ahead: 0, behind: false);

  /// The budget for [pref] on the current link: [metered] is a
  /// cellular-only connection (`OfflineModeProvider.isCellularOnly`).
  static ReelDataBudget of(ReelCellular pref, {required bool metered}) {
    if (!metered) return full;
    return switch (pref) {
      ReelCellular.normal => full,
      ReelCellular.dataSaver => saver,
      ReelCellular.stillsOnly => stills,
    };
  }

  /// Whether any clip plays. False is the stills path.
  final bool clips;

  /// Players kept open ahead of the card on screen.
  final int ahead;

  /// Whether the card behind keeps its player.
  final bool behind;

  /// For logs.
  final String name;

  @override
  String toString() => name;
}
