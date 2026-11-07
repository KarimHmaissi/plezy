import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/copy_fallback.dart';
import 'package:plezy/mpv/models.dart';
import 'package:plezy/screens/video_player/playback_failure_action.dart';

void main() {
  CopyFallbackReason? reasonFor(PlaybackFailureAction action, {String? cause, Set<int> statuses = const {}}) =>
      copyFallbackReasonFor(action: action, cause: cause, httpStatuses: statuses);

  group('which failures move on to another copy', () {
    test('503 for the whole open window, 404 and 410 are about the file', () {
      expect(reasonFor(PlaybackFailureAction.serverBusyDialog), CopyFallbackReason.http503);
      expect(reasonFor(PlaybackFailureAction.mediaUnreadableDialog), CopyFallbackReason.http404);
      expect(reasonFor(PlaybackFailureAction.fatal, statuses: {410}), CopyFallbackReason.http410);
    });

    test('a stalled open, a decoder that would not start and a failed open move on', () {
      expect(reasonFor(PlaybackFailureAction.fatal, cause: PlayerError.openTimedOut), CopyFallbackReason.timedOut);
      expect(
        reasonFor(PlaybackFailureAction.fatal, cause: PlayerError.streamInitFailed),
        CopyFallbackReason.streamInit,
      );
      expect(reasonFor(PlaybackFailureAction.fatal), CopyFallbackReason.openFailed);
    });

    test('a refusal of the account, the server limit, a dead output or core keep their own handling', () {
      expect(reasonFor(PlaybackFailureAction.playbackNotAllowedDialog), isNull);
      expect(reasonFor(PlaybackFailureAction.serverLimitDialog), isNull);
      expect(reasonFor(PlaybackFailureAction.fatal, cause: PlayerError.audioOutputFailed), isNull);
      expect(reasonFor(PlaybackFailureAction.fatal, cause: PlayerError.playerInitFailed), isNull);
      for (final action in [
        PlaybackFailureAction.ignore,
        PlaybackFailureAction.liveRetry,
        PlaybackFailureAction.liveInterrupted,
      ]) {
        expect(reasonFor(action), isNull, reason: action.name);
      }
    });
  });

  group('when the fallback may act', () {
    bool applies({
      bool isLive = false,
      bool isPlexBacked = true,
      bool isLocalPlayback = false,
      bool firstFrameRendered = false,
      bool inWatchTogetherRoom = false,
      bool strictMediaSelection = false,
    }) => copyFallbackApplies(
      isLive: isLive,
      isPlexBacked: isPlexBacked,
      isLocalPlayback: isLocalPlayback,
      firstFrameRendered: firstFrameRendered,
      inWatchTogetherRoom: inWatchTogetherRoom,
      strictMediaSelection: strictMediaSelection,
    );

    test('an on-demand Plex stream before its first frame', () {
      expect(applies(), isTrue);
    });

    test('never once the file played, nor for live TV, other backends, downloads, a room or an exact launch', () {
      expect(applies(firstFrameRendered: true), isFalse);
      expect(applies(isLive: true), isFalse);
      expect(applies(isPlexBacked: false), isFalse);
      expect(applies(isLocalPlayback: true), isFalse);
      expect(applies(inWatchTogetherRoom: true), isFalse);
      expect(applies(strictMediaSelection: true), isFalse);
    });
  });
}
