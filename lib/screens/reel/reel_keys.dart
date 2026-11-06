import 'package:flutter/services.dart';

import '../../focus/transport_keys.dart';
import '../../services/reel/clip_player.dart';
import '../../services/reel/reel_controller.dart';
import '../../services/settings_service.dart';

/// What a remote's media key does on a Reel card (V2-50).
enum ReelMediaKeyAction {
  /// FF / RW and the skip keys: move within the clip.
  seek,

  /// Next / previous track: the next or previous card, like ↓ / ↑.
  step,
}

/// How far a seek key moves within the clip.
const Duration reelSeekStep = Duration(seconds: 10);

/// Maps every hardware skip and track key to what it does on a card, and
/// which way (±1); null for any other key. A remote or a CEC bridge may send
/// either family for the same button, so both are taken: the skip keys
/// ([classifyMediaSeekKey]) seek within the clip, the track keys
/// ([classifyMediaTrackKey]) move a card, the way a track key moves a song.
({ReelMediaKeyAction action, int dir})? reelMediaKey(LogicalKeyboardKey key) {
  final seek = classifyMediaSeekKey(key);
  if (seek != null) return (action: ReelMediaKeyAction.seek, dir: _sign(seek));
  final track = classifyMediaTrackKey(key);
  if (track != null) return (action: ReelMediaKeyAction.step, dir: _sign(track));
  return null;
}

int _sign(MediaSeekDirection d) => d == MediaSeekDirection.forward ? 1 : -1;

/// What a short OK press does on the card showing.
enum ReelOkTarget { replay, nextDeck, retry, watch, details }

/// A held clip replays, the pool end moves on a deck and a failed deck
/// loads again; otherwise OK follows the viewer's choice (D12): Watch, the
/// default, or Details.
ReelOkTarget reelOkTarget({required ClipPhase phase, required ReelSlotKind kind, required ReelOkAction okAction}) {
  if (phase == ClipPhase.held) return ReelOkTarget.replay;
  if (kind == ReelSlotKind.poolEnd) return ReelOkTarget.nextDeck;
  if (kind == ReelSlotKind.failed) return ReelOkTarget.retry;
  return okAction == ReelOkAction.details ? ReelOkTarget.details : ReelOkTarget.watch;
}

/// The TV's key hint line, which follows what OK does.
String reelHintLine({required bool held, ReelOkAction okAction = ReelOkAction.watch}) {
  final ok = held
      ? 'OK replay'
      : okAction == ReelOkAction.details
      ? 'OK details'
      : 'OK watch';
  return '$ok  ·  ↓ next  ·  → next deck  ·  hold OK for more';
}

/// A key as the remote sent it, for the `[ReelKey]` log: the remote's own
/// buttons and a TV's CEC bridge can report different codes for the same
/// press, which only a device session shows.
String reelKeyLogLine(KeyEvent event) {
  final logical = event.logicalKey;
  final name = logical.debugName ?? logical.keyLabel;
  return '[ReelKey] $name logical=0x${logical.keyId.toRadixString(16)} '
      'physical=0x${event.physicalKey.usbHidUsage.toRadixString(16)}';
}
