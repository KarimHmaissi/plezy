import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../focus/input_mode_tracker.dart';
import '../../models/companion_remote/remote_command.dart';
import '../../utils/app_logger.dart';
import '../../utils/key_event_simulator.dart';

class CompanionRemoteReceiver {
  CompanionRemoteReceiver._();

  static CompanionRemoteReceiver? _instance;

  static CompanionRemoteReceiver get instance {
    _instance ??= CompanionRemoteReceiver._();
    return _instance!;
  }

  /// Owners prevent a disposed screen from clearing callbacks installed by a
  /// replacement screen later in the same frame.
  Object? navigationOwner;
  Object? playerOwner;
  VoidCallback? playerHomeFallback;

  VoidCallback? onTabNext;
  VoidCallback? onTabPrevious;
  VoidCallback? onTabDiscover;
  VoidCallback? onTabLibraries;
  VoidCallback? onTabSearch;
  VoidCallback? onTabDownloads;
  VoidCallback? onTabSettings;
  VoidCallback? onHome;
  void Function(String? query)? onSearchAction;
  void Function(Map<String, dynamic> data)? onAiAsk;
  void Function(Map<String, dynamic> data)? onPlayMedia;
  void Function(Map<String, dynamic> data)? onOpenItem;
  VoidCallback? onNextTrack;
  VoidCallback? onPreviousTrack;
  VoidCallback? onStop;
  VoidCallback? onSeekForward;
  VoidCallback? onSeekBackward;
  VoidCallback? onVolumeUp;
  VoidCallback? onVolumeDown;
  VoidCallback? onVolumeMute;
  VoidCallback? onSubtitles;
  VoidCallback? onAudioTracks;
  VoidCallback? onFullscreen;

  /// Fork, now playing: direct player control from the phone, so it works
  /// whatever has focus on the host.
  VoidCallback? onPlayPause;
  void Function(Duration position)? onSeekTo;
  void Function(String kind, String id)? onSelectTrack;

  /// Fork, mirror (host side): a phone's data requests and edits.
  VoidCallback? onMirrorRequest;
  void Function(Map<String, dynamic> data)? onMirrorWrite;
  void Function(Map<String, dynamic> data)? onAiAction;

  /// Skip the intro / credits marker the player is in; set by the controls.
  VoidCallback? onSkipMarker;

  /// The live music session's transport, installed by the session for its
  /// lifetime; returns whether it acted on the command. Transport commands go
  /// here while no video player owns the slots above: the space key that
  /// play/pause otherwise simulates only toggles the video player, and
  /// seek/next/previous/stop have no other handler.
  bool Function(RemoteCommandType type)? musicTransport;

  void handleCommand(RemoteCommand command, BuildContext? _) {
    appLogger.d('CompanionRemoteReceiver: Handling command: ${command.type}');

    // A paired phone cannot point, so any viewer command is evidence of a
    // pointerless device. Protocol frames are not viewer input: promoting on the
    // periodic ping would flip an idle desktop host into keyboard mode — and hide
    // its cursor — on every heartbeat.
    if (_isViewerInput(command.type)) {
      InputModeTracker.reportNonPointerInput();
      scheduleFrameIfIdle();
    }

    if (playerOwner == null && _isTransport(command.type) && (musicTransport?.call(command.type) ?? false)) return;

    switch (command.type) {
      case RemoteCommandType.dpadUp:
        simulateKeyPress(LogicalKeyboardKey.arrowUp);
      case RemoteCommandType.dpadDown:
        simulateKeyPress(LogicalKeyboardKey.arrowDown);
      case RemoteCommandType.dpadLeft:
        simulateKeyPress(LogicalKeyboardKey.arrowLeft);
      case RemoteCommandType.dpadRight:
        simulateKeyPress(LogicalKeyboardKey.arrowRight);
      case RemoteCommandType.select:
        simulateKeyPress(LogicalKeyboardKey.enter);
      case RemoteCommandType.back:
        simulateKeyPress(LogicalKeyboardKey.gameButtonB);
      case RemoteCommandType.contextMenu:
        simulateKeyPress(LogicalKeyboardKey.contextMenu);

      case RemoteCommandType.play:
      case RemoteCommandType.pause:
      case RemoteCommandType.playPause:
        if (onPlayPause != null) {
          onPlayPause!();
        } else {
          simulateKeyPress(LogicalKeyboardKey.space);
        }
      case RemoteCommandType.seekTo:
        final ms = command.data?['positionMs'];
        if (ms is int) onSeekTo?.call(Duration(milliseconds: ms));
      case RemoteCommandType.selectTrack:
        final kind = command.data?['kind'];
        final id = command.data?['id'];
        if (kind is String && id is String) onSelectTrack?.call(kind, id);
      case RemoteCommandType.skipIntro:
      case RemoteCommandType.skipCredits:
        onSkipMarker?.call();
      case RemoteCommandType.mirrorRequest:
        onMirrorRequest?.call();
      case RemoteCommandType.mirrorWrite:
        onMirrorWrite?.call(command.data ?? const {});
      case RemoteCommandType.aiAction:
        onAiAction?.call(command.data ?? const {});
      case RemoteCommandType.seekForward:
        onSeekForward?.call();
      case RemoteCommandType.seekBackward:
        onSeekBackward?.call();

      case RemoteCommandType.volumeUp:
        onVolumeUp?.call();
      case RemoteCommandType.volumeDown:
        onVolumeDown?.call();
      case RemoteCommandType.volumeMute:
        onVolumeMute?.call();

      case RemoteCommandType.tabNext:
        onTabNext?.call();
      case RemoteCommandType.tabPrevious:
        onTabPrevious?.call();
      case RemoteCommandType.tabDiscover:
        onTabDiscover?.call();
      case RemoteCommandType.tabLibraries:
        onTabLibraries?.call();
      case RemoteCommandType.tabSearch:
        onTabSearch?.call();
      case RemoteCommandType.tabDownloads:
        onTabDownloads?.call();
      case RemoteCommandType.tabSettings:
        onTabSettings?.call();

      case RemoteCommandType.home:
        onHome?.call();
      case RemoteCommandType.search:
        final query = command.data?['query'] as String?;
        onSearchAction?.call(query);
      case RemoteCommandType.playMedia:
        onPlayMedia?.call(command.data ?? const {});
      case RemoteCommandType.openItem:
        onOpenItem?.call(command.data ?? const {});
      case RemoteCommandType.aiAsk:
        onAiAsk?.call(command.data ?? const {});

      case RemoteCommandType.stop:
        onStop?.call();
      case RemoteCommandType.nextTrack:
        onNextTrack?.call();
      case RemoteCommandType.previousTrack:
        onPreviousTrack?.call();

      case RemoteCommandType.subtitles:
        onSubtitles?.call();
      case RemoteCommandType.audioTracks:
        onAudioTracks?.call();

      case RemoteCommandType.fullscreen:
        if (onFullscreen != null) {
          onFullscreen!.call();
        } else {
          simulateKeyPress(LogicalKeyboardKey.keyF);
        }

      case RemoteCommandType.ping:
      case RemoteCommandType.pong:
      case RemoteCommandType.ack:
      case RemoteCommandType.deviceInfo:
      case RemoteCommandType.disconnect:
      case RemoteCommandType.syncState:
      case RemoteCommandType.castResult:
      case RemoteCommandType.aiAnswer:
      case RemoteCommandType.nowPlaying:
      case RemoteCommandType.mirrorSnapshot:
      case RemoteCommandType.aiActivity:
        break;

      default:
        appLogger.w('CompanionRemoteReceiver: Unhandled command type: ${command.type}');
    }
  }
}

bool _isTransport(RemoteCommandType type) => switch (type) {
  RemoteCommandType.play ||
  RemoteCommandType.pause ||
  RemoteCommandType.playPause ||
  RemoteCommandType.stop ||
  RemoteCommandType.seekForward ||
  RemoteCommandType.seekBackward ||
  RemoteCommandType.nextTrack ||
  RemoteCommandType.previousTrack => true,
  _ => false,
};

/// Exhaustive by design: no default clause, so adding a [RemoteCommandType]
/// is a compile error until someone decides whether it counts as viewer input.
bool _isViewerInput(RemoteCommandType type) => switch (type) {
  RemoteCommandType.ping ||
  RemoteCommandType.pong ||
  RemoteCommandType.ack ||
  RemoteCommandType.deviceInfo ||
  RemoteCommandType.disconnect ||
  RemoteCommandType.syncState ||
  RemoteCommandType.castResult ||
  RemoteCommandType.aiAnswer ||
  RemoteCommandType.nowPlaying ||
  RemoteCommandType.mirrorRequest ||
  RemoteCommandType.mirrorSnapshot ||
  RemoteCommandType.mirrorWrite ||
  RemoteCommandType.aiAction ||
  RemoteCommandType.aiActivity => false,
  RemoteCommandType.dpadUp ||
  RemoteCommandType.dpadDown ||
  RemoteCommandType.dpadLeft ||
  RemoteCommandType.dpadRight ||
  RemoteCommandType.select ||
  RemoteCommandType.back ||
  RemoteCommandType.contextMenu ||
  RemoteCommandType.play ||
  RemoteCommandType.pause ||
  RemoteCommandType.playPause ||
  RemoteCommandType.stop ||
  RemoteCommandType.seekForward ||
  RemoteCommandType.seekBackward ||
  RemoteCommandType.nextTrack ||
  RemoteCommandType.previousTrack ||
  RemoteCommandType.skipIntro ||
  RemoteCommandType.skipCredits ||
  RemoteCommandType.volumeUp ||
  RemoteCommandType.volumeDown ||
  RemoteCommandType.volumeMute ||
  RemoteCommandType.volumeSet ||
  RemoteCommandType.tabNext ||
  RemoteCommandType.tabPrevious ||
  RemoteCommandType.tabDiscover ||
  RemoteCommandType.tabLibraries ||
  RemoteCommandType.tabSearch ||
  RemoteCommandType.tabDownloads ||
  RemoteCommandType.tabSettings ||
  RemoteCommandType.home ||
  RemoteCommandType.search ||
  RemoteCommandType.aiAsk ||
  RemoteCommandType.playMedia ||
  RemoteCommandType.openItem ||
  RemoteCommandType.seekTo ||
  RemoteCommandType.selectTrack ||
  RemoteCommandType.subtitles ||
  RemoteCommandType.audioTracks ||
  RemoteCommandType.qualitySettings ||
  RemoteCommandType.fullscreen => true,
};
