import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:os_media_controls/os_media_controls.dart';

import '../../media/media_server_client.dart';
import '../../models/companion_remote/remote_command.dart';
import '../../providers/companion_remote_provider.dart';
import '../../screens/companion_remote/now_playing_screen.dart';
import '../../utils/app_logger.dart';
import '../../utils/notification_permission.dart';
import '../media_controls_manager.dart';

/// Players on this device that own the OS media session (the video screen,
/// the music service). While any is active the phone's own playback has the
/// notification, and [HostMediaNotification] stands aside.
abstract final class LocalMediaSession {
  static final Set<Object> _owners = {};
  static final ValueNotifier<bool> active = ValueNotifier(false);

  static void claim(Object owner) {
    _owners.add(owner);
    active.value = true;
  }

  static void release(Object owner) {
    _owners.remove(owner);
    active.value = _owners.isNotEmpty;
  }
}

/// Phone side of casting: while the TV app it's connected to is playing,
/// the phone shows a media notification (shade, lock screen, Samsung's quick
/// panel player) for it, through the same OS media session the phone's own
/// playback uses. Its buttons send remote commands to the TV.
class HostMediaNotification {
  HostMediaNotification._();
  static final HostMediaNotification instance = HostMediaNotification._();

  CompanionRemoteProvider? _remote;
  MediaServerClient? Function(String? serverId)? _clientFor;
  MediaControlsManager? _controls;
  StreamSubscription<MediaControlEvent>? _events;
  String? _shownKey;
  String? _shownState;

  void start(CompanionRemoteProvider remote, {required MediaServerClient? Function(String? serverId) clientFor}) {
    if (!Platform.isAndroid || identical(_remote, remote)) return;
    _remote?.nowPlaying.removeListener(_sync);
    _remote?.removeListener(_sync);
    _remote = remote;
    _clientFor = clientFor;
    remote.nowPlaying.addListener(_sync);
    remote.addListener(_sync);
    LocalMediaSession.active.addListener(_sync);
    _sync();
  }

  bool get _wanted {
    final remote = _remote;
    return remote != null &&
        remote.isRemote &&
        remote.isConnected &&
        remote.nowPlaying.value != null &&
        !LocalMediaSession.active.value;
  }

  void _sync() {
    if (!_wanted) {
      unawaited(_hide());
      return;
    }
    final now = HostNowPlaying(_remote!.nowPlaying.value!);
    unawaited(_show(now));
  }

  Future<void> _show(HostNowPlaying now) async {
    var controls = _controls;
    if (controls == null) {
      controls = _controls = MediaControlsManager();
      _events = controls.controlEvents.listen(_onEvent);
      unawaited(NotificationPermission.ensure());
      await controls.setBackgroundMode(true);
    }
    final key = '${now.serverId}|${now.title}|${now.subtitle}|${now.thumb ?? now.art ?? now.poster}';
    if (key != _shownKey) {
      _shownKey = key;
      final image = now.thumb ?? now.art ?? now.poster;
      String? artworkUrl;
      if (image != null) {
        try {
          artworkUrl = _clientFor?.call(now.serverId)?.thumbnailUrl(image);
        } catch (e) {
          appLogger.d('Cast notification: no artwork URL', error: e);
        }
      }
      try {
        await OsMediaControls.setMetadata(
          MediaMetadata(
            title: now.title,
            artist: now.subtitle.isNotEmpty ? now.subtitle : (_remote?.connectedDevice?.name ?? ''),
            artworkUrl: artworkUrl,
            duration: now.duration > Duration.zero ? now.duration : null,
          ),
        );
      } catch (e) {
        appLogger.w('Cast notification: metadata failed', error: e);
      }
    }
    if (!identical(controls, _controls)) return;
    await controls.setControlsEnabled(
      canPlayPause: true,
      canGoNext: now.hasNext,
      canGoPrevious: now.hasPrevious,
      canSeek: now.duration > Duration.zero,
      canStop: true,
      canSkip: true,
      skipInterval: const Duration(seconds: 10),
    );
    // A play/pause flip goes out at once; position ticks ride the throttle.
    final stateChanged = now.state != _shownState;
    _shownState = now.state;
    await controls.updatePlaybackState(
      isPlaying: now.playing,
      position: now.position,
      speed: 1,
      force: stateChanged,
    );
  }

  Future<void> _hide() async {
    final controls = _controls;
    if (controls == null) return;
    _controls = null;
    _shownKey = null;
    _shownState = null;
    unawaited(_events?.cancel());
    _events = null;
    // A local player taking over sets up the session itself; clearing here
    // would race it.
    if (LocalMediaSession.active.value) {
      controls.dispose();
      return;
    }
    await controls.setBackgroundMode(false);
    await controls.clear();
    controls.dispose();
  }

  void _onEvent(MediaControlEvent event) {
    final remote = _remote;
    if (remote == null || _controls == null || LocalMediaSession.active.value) return;
    final now = remote.nowPlaying.value == null ? null : HostNowPlaying(remote.nowPlaying.value!);
    switch (event) {
      case PlayEvent():
        if (now != null && !now.playing) remote.sendCommand(RemoteCommandType.playPause);
      case PauseEvent():
        if (now != null && now.playing) remote.sendCommand(RemoteCommandType.playPause);
      case TogglePlayPauseEvent():
        remote.sendCommand(RemoteCommandType.playPause);
      case SeekEvent(:final position):
        remote.seekHostTo(position);
      case SkipForwardEvent():
        remote.sendCommand(RemoteCommandType.seekForward);
      case SkipBackwardEvent():
        remote.sendCommand(RemoteCommandType.seekBackward);
      case NextTrackEvent():
        remote.sendCommand(RemoteCommandType.nextTrack);
      case PreviousTrackEvent():
        remote.sendCommand(RemoteCommandType.previousTrack);
      case StopEvent():
        remote.sendCommand(RemoteCommandType.stop);
      default:
        break;
    }
  }
}
