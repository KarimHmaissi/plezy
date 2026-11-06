import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import '../../services/settings_service.dart';
import '../../utils/platform_detector.dart';
import '../../widgets/setting_tile.dart';
import '../../widgets/settings_page.dart';
import '../../widgets/settings_section.dart';
import 'settings_utils.dart';

/// Fork: the Reel's settings (plan V2-46), from the fork group in Settings
/// and "Reel settings" in the Reel's own sheet. These are this device's
/// prefs (V2-46a): the TV and the phone each keep their own. A playing Reel
/// takes a change up at once (`ReelController.settingsChanged`), and Show
/// the Reel tab brings the tab and rail item in or out like Explore's
/// toggle.
class ReelSettingsScreen extends StatelessWidget {
  const ReelSettingsScreen({super.key, this.tv});

  /// The TV layout (OK button, no mobile data row). Defaults to this device.
  final bool? tv;

  @override
  Widget build(BuildContext context) {
    final isTv = tv ?? PlatformDetector.isTV();
    final s = t.reel.settings;
    return SettingsPage(
      title: Text(s.title),
      children: [
        SettingsGroup(
          title: s.playing,
          children: [
            _startSound(),
            _clipEnd(),
            if (isTv) _okAction() else _cellular(),
            SettingSwitchTile(
              pref: SettingsService.reelCaptions,
              icon: Symbols.lyrics_rounded,
              title: s.captions,
              subtitle: s.captionsDescription,
            ),
          ],
        ),
        SettingsGroup(
          title: t.settings.navigation,
          children: [
            SettingSwitchTile(
              pref: SettingsService.showReelTab,
              icon: Symbols.movie_rounded,
              title: s.showTab,
              subtitle: s.showTabDescription,
            ),
          ],
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  static String startSoundLabel(ReelStartSound v) => switch (v) {
    ReelStartSound.sound => t.reel.settings.startSoundOn,
    ReelStartSound.mutedIfOtherAudio => t.reel.settings.startSoundMutedIfOtherAudio,
  };

  static String clipEndLabel(ReelClipEnd v) => switch (v) {
    ReelClipEnd.loop => t.reel.settings.clipEndLoop,
    ReelClipEnd.twiceThenHold => t.reel.settings.clipEndTwiceThenHold,
    ReelClipEnd.nextCard => t.reel.settings.clipEndNextCard,
  };

  static String cellularLabel(ReelCellular v) => switch (v) {
    ReelCellular.normal => t.reel.settings.cellularNormal,
    ReelCellular.dataSaver => t.reel.settings.cellularDataSaver,
    ReelCellular.stillsOnly => t.reel.settings.cellularStillsOnly,
  };

  Widget _startSound() {
    final s = t.reel.settings;
    return SettingSelectionTile<ReelStartSound>(
      pref: SettingsService.reelStartSound,
      icon: Symbols.volume_up_rounded,
      title: s.startSound,
      subtitleBuilder: startSoundLabel,
      options: [
        DialogOption(value: ReelStartSound.sound, title: s.startSoundOn),
        DialogOption(
          value: ReelStartSound.mutedIfOtherAudio,
          title: s.startSoundMutedIfOtherAudio,
          subtitle: s.startSoundMutedIfOtherAudioDescription,
        ),
      ],
    );
  }

  Widget _clipEnd() {
    final s = t.reel.settings;
    return SettingSelectionTile<ReelClipEnd>(
      pref: SettingsService.reelClipEnd,
      icon: Symbols.repeat_rounded,
      title: s.clipEnd,
      subtitleBuilder: clipEndLabel,
      options: [
        DialogOption(value: ReelClipEnd.loop, title: s.clipEndLoop),
        DialogOption(
          value: ReelClipEnd.twiceThenHold,
          title: s.clipEndTwiceThenHold,
          subtitle: s.clipEndTwiceThenHoldDescription,
        ),
        DialogOption(value: ReelClipEnd.nextCard, title: s.clipEndNextCard, subtitle: s.clipEndNextCardDescription),
      ],
    );
  }

  /// TV only: what OK does on a card (D12).
  Widget _okAction() {
    final s = t.reel.settings;
    return SettingSegmentedTile<ReelOkAction>(
      pref: SettingsService.reelOkAction,
      icon: Symbols.settings_remote_rounded,
      title: s.okAction,
      segments: [
        ButtonSegment(value: ReelOkAction.watch, label: Text(s.okActionWatch)),
        ButtonSegment(value: ReelOkAction.details, label: Text(s.okActionDetails)),
      ],
    );
  }

  /// Phone only: the Reel on mobile data (V2-53). Each choice states its
  /// trade.
  Widget _cellular() {
    final s = t.reel.settings;
    return SettingSelectionTile<ReelCellular>(
      pref: SettingsService.reelCellular,
      icon: Symbols.signal_cellular_alt_rounded,
      title: s.cellular,
      subtitleBuilder: cellularLabel,
      options: [
        DialogOption(value: ReelCellular.normal, title: s.cellularNormal, subtitle: s.cellularNormalDescription),
        DialogOption(
          value: ReelCellular.dataSaver,
          title: s.cellularDataSaver,
          subtitle: s.cellularDataSaverDescription,
        ),
        DialogOption(
          value: ReelCellular.stillsOnly,
          title: s.cellularStillsOnly,
          subtitle: s.cellularStillsOnlyDescription,
        ),
      ],
    );
  }
}
