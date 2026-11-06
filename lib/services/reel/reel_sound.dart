import 'dart:io';

import 'package:flutter/services.dart';

import '../../utils/app_logger.dart';
import '../../utils/device_channel.dart';
import '../settings_service.dart';

/// How the phone feed's sound starts (V2-22, plan D5).
///
/// With [ReelStartSound.sound] (the default) the feed's players take audio
/// focus: music pauses when a card plays, and a call pauses the card
/// (media3 does both once `mixWithOthers` is off). With
/// [ReelStartSound.mutedIfOtherAudio] the players mix with other audio
/// instead, and a visit starts muted while other audio is playing, so the
/// music carries on.
abstract final class ReelSound {
  /// Whether the feed's players mix with other audio rather than take audio
  /// focus. `video_player_android` hands this to media3 as
  /// `handleAudioFocus = !mixWithOthers` when each player is created.
  static bool mixWithOthers(ReelStartSound pref) => pref == ReelStartSound.mutedIfOtherAudio;

  /// Whether a visit to the feed starts muted: the saved mute
  /// ([SettingsService.reelMuted]), or, without saving it, while the
  /// connected TV is playing ([tvPlaying]) or, with
  /// [ReelStartSound.mutedIfOtherAudio], while other audio is playing.
  static bool startMuted({
    required bool saved,
    required ReelStartSound pref,
    bool tvPlaying = false,
    bool otherAudio = false,
  }) => saved || tvPlaying || (pref == ReelStartSound.mutedIfOtherAudio && otherAudio);

  /// Whether the companion's `nowPlaying` update says the TV is playing
  /// (it sends `playing`, `paused` or `stopped`).
  static bool tvPlaying(Map<String, dynamic>? nowPlaying) => nowPlaying?['state'] == 'playing';

  /// Whether another app's audio is playing now (Android's
  /// `AudioManager.isMusicActive`). Asked only before the feed's own players
  /// start, so it never counts the Reel itself. False where it can't be
  /// told.
  static Future<bool> otherAudioPlaying() async {
    if (!Platform.isAndroid) return false;
    try {
      return await deviceChannel.invokeMethod<bool>('isMusicActive') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      appLogger.d('Reel: could not tell whether other audio is playing', error: e);
      return false;
    }
  }
}
