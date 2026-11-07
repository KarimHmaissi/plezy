import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import '../../services/reel/reel_clip_cache.dart';
import '../../services/reel/reel_developer.dart';
import '../../services/settings_service.dart';
import '../../utils/platform_detector.dart';
import '../../widgets/setting_tile.dart';
import '../../widgets/settings_page.dart';
import '../../widgets/settings_section.dart';
import 'reel_clip_cache_tile.dart';
import 'reel_decks_screen.dart';
import 'reel_for_you_tiles.dart';
import 'settings_utils.dart';

/// Fork: the Reel's settings (plan V2-46), from the fork group in Settings
/// and "Reel settings" in the Reel's own sheet. These are this device's
/// prefs (V2-46a): the TV and the phone each keep their own. A playing Reel
/// takes a change up at once (`ReelController.settingsChanged`), and Show
/// the Reel tab brings the tab and rail item in or out like Explore's
/// toggle. Decks (order, hidden decks, start deck; synced) have their own
/// screen ([ReelDecksScreen]). For You's note and today's rebuild (V2-51,
/// synced) sit in their own group ([ReelForYouTiles]). The hidden developer
/// setting (V2-62) shows last, only in a debug build or while debug logging
/// is on; on the TV it also holds the clip loudness switch (V2-19). The TV
/// has a Clear Reel cache row for its clip core's disk cache (V2-10); the
/// phone's feed plays on its own players and never writes that cache.
class ReelSettingsScreen extends StatelessWidget {
  const ReelSettingsScreen({
    super.key,
    this.tv,
    @visibleForTesting this.debugBuild = kDebugMode,
    @visibleForTesting this.clipCache,
  });

  /// The TV layout (OK button, no mobile data row). Defaults to this device.
  final bool? tv;

  /// A debug build: the developer setting always shows.
  final bool debugBuild;

  /// The clip disk cache the Clear row works on; [ReelClipCache.instance]
  /// by default.
  final ReelClipCache? clipCache;

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
            _startSound(tv: isTv),
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
          title: t.reel.decks.title,
          children: [
            SettingNavigationTile(
              icon: Symbols.view_carousel_rounded,
              title: t.reel.decks.title,
              subtitle: t.reel.decks.subtitle,
              destinationBuilder: (_) => const ReelDecksScreen(),
            ),
          ],
        ),
        // Synced: the same note and rebuild on the TV and the phone, whether
        // or not this phone uses the TV's AI.
        SettingsGroup(title: t.reelForYou.title, children: const [ReelForYouTiles(showTitle: false)]),
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
        if (isTv && (clipCache ?? ReelClipCache.instance).supported)
          SettingsGroup(
            title: s.storage,
            children: [ReelClipCacheTile(cache: clipCache)],
          ),
        if (ReelDeveloper.visible(debugBuild: debugBuild))
          SettingsGroup(
            title: s.developer,
            children: [
              SettingSwitchTile(
                pref: SettingsService.reelDebugOverlay,
                icon: Symbols.developer_mode_rounded,
                title: s.developerTools,
                subtitle: s.developerToolsDescription,
              ),
              // The TV's clip core only: the phone feed plays on its own
              // players (V2-19, D9: off until a listening A/B).
              if (isTv)
                SettingSwitchTile(
                  pref: SettingsService.reelClipNormalization,
                  icon: Symbols.graphic_eq_rounded,
                  title: s.clipNormalization,
                  subtitle: s.clipNormalizationDescription,
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
    ReelStartSound.muted => t.reel.settings.startSoundMuted,
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

  /// The mobile-data row's subtitle: Data saver states its trade (V2-53).
  static String cellularSubtitle(ReelCellular v) =>
      v == ReelCellular.dataSaver ? t.reel.settings.cellularDataSaverSubtitle : cellularLabel(v);

  /// How a visit's sound starts. The TV has its own pref, start muted unless
  /// changed (it can't tell other audio apart, so it offers only the two);
  /// the phone's starts with sound.
  Widget _startSound({required bool tv}) {
    final s = t.reel.settings;
    return SettingSelectionTile<ReelStartSound>(
      pref: tv ? SettingsService.reelTvStartSound : SettingsService.reelStartSound,
      icon: Symbols.volume_up_rounded,
      title: s.startSound,
      subtitleBuilder: startSoundLabel,
      options: [
        if (tv)
          DialogOption(value: ReelStartSound.muted, title: s.startSoundMuted, subtitle: s.startSoundMutedDescription),
        DialogOption(value: ReelStartSound.sound, title: s.startSoundOn),
        if (!tv)
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
      subtitleBuilder: cellularSubtitle,
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
