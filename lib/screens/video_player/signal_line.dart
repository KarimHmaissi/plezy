import '../../i18n/strings.g.dart';
import '../../mpv/mpv.dart';
import '../../utils/codec_utils.dart';

/// "23.976 matched · Direct Play · E-AC3 5.1": the content rate and what the
/// display did about it, the server's play method, and the audio stream. Null
/// when none of the parts is known.
///
/// [switched] is the Android switch result for [fps]: true when the display
/// moved to a mode for it, false when the request changed nothing (the mode
/// already matched, or the display lists no mode for the rate: the native
/// result does not say which), null when nothing was requested.
/// [transcoding] is null when the stream has no server play method (live TV,
/// offline playback).
String? formatSignalLine({
  double? fps,
  bool? switched,
  bool? transcoding,
  String? audioCodec,
  String? audioCodecProfile,
  int? audioChannels,
}) {
  final parts = <String>[];
  if (fps != null && fps > 0) {
    final rate = formatSignalRate(fps);
    parts.add(switch (switched) {
      true => t.performanceOverlay.rateMatched(rate: rate),
      false => t.performanceOverlay.rateNotSwitched(rate: rate),
      null => rate,
    });
  }
  if (transcoding != null) parts.add(transcoding ? t.fileInfo.transcoding : t.fileInfo.directPlay);
  final audio = [
    if (audioCodec != null && audioCodec.isNotEmpty)
      CodecUtils.formatAudioCodec(audioCodec, profile: audioCodecProfile),
    ?CodecUtils.formatAudioChannels(audioChannels),
  ].join(' ');
  if (audio.isNotEmpty) parts.add(audio);
  return parts.isEmpty ? null : parts.join(' · ');
}

/// 23.976023976 → "23.976", 25.0 → "25", 59.94 → "59.94".
String formatSignalRate(double fps) {
  final fixed = fps.toStringAsFixed(3);
  return fixed.replaceFirst(RegExp(r'\.?0+$'), '');
}

/// What the display did about the current item's frame rate, kept for the
/// signal line. Every Android display request goes through one call site,
/// which reports here; the open notes the metadata rate first so the line
/// still names the rate when matching is off.
class PlaybackSignal {
  String? _itemId;
  double? _fps;
  bool? _switched;

  void _forItem(String? itemId) {
    if (itemId == _itemId) return;
    _itemId = itemId;
    _fps = null;
    _switched = null;
  }

  /// The item's rate as its metadata gives it, before any display request.
  void noteContentFps(String? itemId, double? fps) {
    _forItem(itemId);
    if (_switched == null && fps != null && fps > 0) _fps = fps;
  }

  /// A display request for [fps] returned [switched].
  void noteSwitch(String? itemId, double fps, bool switched) {
    _forItem(itemId);
    if (fps <= 0) return;
    // A reload re-asks for the rate the display already moved to, and the
    // native side answers "no switch": the display is still matched.
    if (!switched && _switched == true && _fps == fps) return;
    _fps = fps;
    _switched = switched;
  }

  String? lineFor(String? itemId, {bool? transcoding, AudioTrack? audio}) {
    final known = itemId == _itemId;
    return formatSignalLine(
      fps: known ? _fps : null,
      switched: known ? _switched : null,
      transcoding: transcoding,
      audioCodec: audio?.codec,
      audioCodecProfile: audio?.codecProfile,
      audioChannels: audio?.channels,
    );
  }

  /// The selected audio track with the most detail the player has for it:
  /// the entry in the track list carries codec and channels.
  static AudioTrack? selectedAudio(PlayerState state) {
    final selected = state.track.audio;
    if (selected == null || selected.id == AudioTrack.off.id) return null;
    return state.tracks.audio.where((track) => track.id == selected.id).firstOrNull ?? selected;
  }
}
