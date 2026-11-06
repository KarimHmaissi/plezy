import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/screens/reel/reel_keys.dart';
import 'package:plezy/services/reel/clip_player.dart';
import 'package:plezy/services/reel/reel_controller.dart';
import 'package:plezy/services/settings_service.dart';

void main() {
  group('reelMediaKey (V2-50)', () {
    test('every skip key seeks within the clip', () {
      for (final (key, dir) in [
        (LogicalKeyboardKey.mediaFastForward, 1),
        (LogicalKeyboardKey.mediaSkipForward, 1),
        (LogicalKeyboardKey.mediaRewind, -1),
        (LogicalKeyboardKey.mediaSkipBackward, -1),
      ]) {
        expect(reelMediaKey(key), (action: ReelMediaKeyAction.seek, dir: dir), reason: key.debugName);
      }
    });

    test('FF asks for More like this where it is offered (V2-39); RW and the skip keys still seek', () {
      expect(reelMediaKey(LogicalKeyboardKey.mediaFastForward, moreLike: true), (
        action: ReelMediaKeyAction.moreLike,
        dir: 1,
      ));
      for (final (key, dir) in [
        (LogicalKeyboardKey.mediaSkipForward, 1),
        (LogicalKeyboardKey.mediaRewind, -1),
        (LogicalKeyboardKey.mediaSkipBackward, -1),
      ]) {
        expect(reelMediaKey(key, moreLike: true), (action: ReelMediaKeyAction.seek, dir: dir), reason: key.debugName);
      }
      expect(reelMediaKey(LogicalKeyboardKey.mediaTrackNext, moreLike: true), (
        action: ReelMediaKeyAction.step,
        dir: 1,
      ));
    });

    test('the track keys move a card', () {
      expect(reelMediaKey(LogicalKeyboardKey.mediaTrackNext), (action: ReelMediaKeyAction.step, dir: 1));
      expect(reelMediaKey(LogicalKeyboardKey.mediaTrackPrevious), (action: ReelMediaKeyAction.step, dir: -1));
    });

    test('play / pause, the arrows and other keys are not media skip keys', () {
      for (final key in [
        LogicalKeyboardKey.mediaPlayPause,
        LogicalKeyboardKey.mediaStop,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.select,
        LogicalKeyboardKey.contextMenu,
      ]) {
        expect(reelMediaKey(key), isNull, reason: key.debugName);
      }
    });

    test('a seek is ten seconds either way', () {
      expect(reelSeekStep * -1, const Duration(seconds: -10));
    });
  });

  group('reelOkTarget (D12)', () {
    test('OK watches by default and opens Details when that is the pref', () {
      for (final phase in [ClipPhase.playing, ClipPhase.paused, ClipPhase.loading, ClipPhase.failed]) {
        expect(reelOkTarget(phase: phase, kind: ReelSlotKind.card, okAction: ReelOkAction.watch), ReelOkTarget.watch);
        expect(
          reelOkTarget(phase: phase, kind: ReelSlotKind.card, okAction: ReelOkAction.details),
          ReelOkTarget.details,
        );
      }
    });

    test("OK on Tonight's picks watches the chosen pick, whatever the pref or the clip behind it (V2-38)", () {
      for (final ok in ReelOkAction.values) {
        for (final phase in ClipPhase.values) {
          expect(reelOkTarget(phase: phase, kind: ReelSlotKind.decide, okAction: ok), ReelOkTarget.watch);
        }
      }
    });

    test('a held clip replays, the pool end moves on and a failed deck retries, whatever the pref', () {
      for (final ok in ReelOkAction.values) {
        expect(reelOkTarget(phase: ClipPhase.held, kind: ReelSlotKind.card, okAction: ok), ReelOkTarget.replay);
        expect(reelOkTarget(phase: ClipPhase.idle, kind: ReelSlotKind.poolEnd, okAction: ok), ReelOkTarget.nextDeck);
        expect(reelOkTarget(phase: ClipPhase.idle, kind: ReelSlotKind.failed, okAction: ok), ReelOkTarget.retry);
      }
    });
  });

  group('reelHintLine', () {
    test('follows what OK does', () {
      expect(reelHintLine(held: false), startsWith('OK watch'));
      expect(reelHintLine(held: false, okAction: ReelOkAction.details), startsWith('OK details'));
      expect(reelHintLine(held: true, okAction: ReelOkAction.details), startsWith('OK replay'));
      expect(reelHintLine(held: false), endsWith('hold OK for more'));
    });

    test('a Give it another go card resumes its episode (V2-40)', () {
      expect(reelHintLine(held: false, resumeEpisode: 'E4'), startsWith('OK resume E4  ·'));
      expect(reelHintLine(held: true, resumeEpisode: 'E4'), startsWith('OK replay'));
      expect(reelHintLine(held: false, okAction: ReelOkAction.details, resumeEpisode: 'E4'), startsWith('OK details'));
    });
  });

  test('reelKeyLogLine names the key and both codes', () {
    final line = reelKeyLogLine(
      const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.mediaTrackNext,
        logicalKey: LogicalKeyboardKey.mediaTrackNext,
        timeStamp: Duration.zero,
      ),
    );
    expect(line, startsWith('[ReelKey] '));
    expect(line, contains('logical=0x${LogicalKeyboardKey.mediaTrackNext.keyId.toRadixString(16)}'));
    expect(line, contains('physical=0x${PhysicalKeyboardKey.mediaTrackNext.usbHidUsage.toRadixString(16)}'));
  });
}
