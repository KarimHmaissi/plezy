import 'dart:io';

import 'package:flutter/services.dart';

import '../../utils/app_logger.dart';
import '../../utils/device_channel.dart';
import '../settings_service.dart';

/// How a visit to the Reel starts its sound (V2-22, plan D5).
///
/// Phone: with [ReelStartSound.sound] (its default) the feed's players take
/// audio focus: music pauses when a card plays, and a call pauses the card
/// (media3 does both once `mixWithOthers` is off). With
/// [ReelStartSound.mutedIfOtherAudio] the players mix with other audio
/// instead, and a visit starts muted while other audio is playing, so the
/// music carries on. [ReelStartSound.muted] mixes too, and every visit
/// starts muted.
///
/// TV: [ReelStartSound.muted] is its default, so the Reel never comes up
/// loud: every visit (the app opened or brought back, the Shield woken, the
/// tab chosen, a link) starts muted, and the card says how to turn the
/// sound on. Only Back from a page the Reel opened (Watch, Details) carries
/// on as the viewer left it ([tvVisitStart]).
abstract final class ReelSound {
  /// Whether the feed's players mix with other audio rather than take audio
  /// focus. `video_player_android` hands this to media3 as
  /// `handleAudioFocus = !mixWithOthers` when each player is created.
  static bool mixWithOthers(ReelStartSound pref) => pref != ReelStartSound.sound;

  /// Whether a visit to the feed starts muted: always with
  /// [ReelStartSound.muted]; otherwise the saved mute
  /// ([SettingsService.reelMuted]), or, without saving it, while the
  /// connected TV is playing ([tvPlaying]) or, with
  /// [ReelStartSound.mutedIfOtherAudio], while other audio is playing.
  static bool startMuted({
    required bool saved,
    required ReelStartSound pref,
    bool tvPlaying = false,
    bool otherAudio = false,
  }) => pref == ReelStartSound.muted || saved || tvPlaying || (pref == ReelStartSound.mutedIfOtherAudio && otherAudio);

  /// How a TV visit starts its sound, and why (the `[ReelSound]` log).
  /// [muted] null: Back from a page the Reel opened ([backFromPage]), which
  /// keeps the sound as the viewer left it. Otherwise the visit is muted
  /// unless the pref is [ReelStartSound.sound] (a phone's "Muted if other
  /// audio is playing", carried over by a settings import, reads as muted:
  /// the TV doesn't mix), and with sound it still starts muted when the mute
  /// was kept ([saved]) or a screen reader is on (V2-54).
  static ({bool? muted, String why}) tvVisitStart({
    required ReelStartSound pref,
    required bool saved,
    bool screenReader = false,
    bool backFromPage = false,
  }) {
    if (backFromPage) return (muted: null, why: 'back from a page: as the viewer left it');
    if (pref != ReelStartSound.sound) return (muted: true, why: 'start muted (${pref.name})');
    if (saved) return (muted: true, why: 'kept mute');
    if (screenReader) return (muted: true, why: 'screen reader');
    return (muted: false, why: 'with sound');
  }

  /// Why a phone visit starts as it does, for the `[ReelSound]` log.
  static String phoneWhy({
    required bool muted,
    required ReelStartSound pref,
    required bool saved,
    bool screenReader = false,
    bool tvPlaying = false,
  }) {
    if (!muted) return 'with sound';
    if (pref == ReelStartSound.muted) return 'start muted (${pref.name})';
    if (saved) return 'kept mute';
    if (screenReader) return 'screen reader';
    if (tvPlaying) return 'the TV is playing';
    return 'other audio is playing';
  }

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
