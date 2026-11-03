import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../media/media_item.dart';
import '../../models/companion_remote/remote_command.dart';
import '../../mpv/mpv.dart';
import '../../providers/companion_remote_provider.dart';
import '../../services/companion_remote/companion_remote_receiver.dart';
import '../../services/companion_remote/host_player_marker.dart';
import '../../services/fullscreen_state_manager.dart';
import '../../services/video_volume_controller.dart';
import '../../utils/app_logger.dart';
import '../../utils/platform_detector.dart';

/// Wires the player screen into the [CompanionRemoteReceiver] callback slots
/// and owns the home-button fallback plus the provider handle used for
/// player-active sync notifications.
///
/// Plain State-owned helper. [bind] installs this instance as the receiver's
/// `playerOwner` token; [unbind] restores the slots only while this instance
/// still owns them, so a replacement screen's wiring survives the outgoing
/// screen's dispose. The player and volume controller are injected as
/// late-bound getters because both are re-created across playback attempts,
/// and volume/seek dispatch must bind to the player at command receipt.
class CompanionRemoteBinding {
  CompanionRemoteBinding({
    required this._player,
    required this._isMounted,
    required this._canControlPlayback,
    required this._volumeController,
    required this._hasNextItem,
    required this._onStop,
    required this._onNavigateToNextItem,
    required this._onNavigateToPreviousItem,
    required this._skipByConfiguredStep,
    required this._onCycleSubtitles,
    required this._onCycleAudio,
    required this._onHome,
    required this._readProvider,
    required this._metadata,
    required this._hasPreviousItem,
    required this._onSelectAudio,
    required this._onSelectSubtitle,
  });

  final MediaItem Function() _metadata;
  final bool Function() _hasPreviousItem;
  final void Function(AudioTrack track) _onSelectAudio;
  final void Function(SubtitleTrack track) _onSelectSubtitle;

  final Player? Function() _player;
  final bool Function() _isMounted;
  final bool Function() _canControlPlayback;
  final VideoVolumeController? Function() _volumeController;
  final bool Function() _hasNextItem;
  final void Function() _onStop;
  final Future<void> Function() _onNavigateToNextItem;
  final Future<void> Function() _onNavigateToPreviousItem;
  final void Function({required bool forward}) _skipByConfiguredStep;
  final void Function() _onCycleSubtitles;
  final void Function() _onCycleAudio;
  final void Function() _onHome;
  final CompanionRemoteProvider Function() _readProvider;

  CompanionRemoteProvider? _provider;
  VoidCallback? _savedOnHome;

  /// The MainScreen home callback saved while this screen overrides the
  /// receiver's home slot; the screen's home-button handler invokes it after
  /// popping back to the first route.
  VoidCallback? get savedOnHome => _savedOnHome;

  void bind() {
    final receiver = CompanionRemoteReceiver.instance;
    receiver.playerHomeFallback ??= receiver.onHome;
    receiver.playerOwner = this;
    receiver.onStop = () {
      if (_isMounted()) _onStop();
    };
    receiver.onNextTrack = () {
      if (_isMounted() && _hasNextItem()) unawaited(_onNavigateToNextItem());
    };
    receiver.onPreviousTrack = () {
      if (_isMounted()) unawaited(_onNavigateToPreviousItem());
    };
    receiver.onSeekForward = () => _dispatchSeek(forward: true);
    receiver.onSeekBackward = () => _dispatchSeek(forward: false);
    receiver.onVolumeUp = () => _dispatchVolume(10);
    receiver.onVolumeDown = () => _dispatchVolume(-10);
    receiver.onVolumeMute = _dispatchMute;
    receiver.onSubtitles = () {
      if (_canControlPlayback()) _onCycleSubtitles();
    };
    receiver.onAudioTracks = () {
      if (_canControlPlayback()) _onCycleAudio();
    };
    receiver.onFullscreen = _toggleFullscreen;
    receiver.onPlayPause = () {
      final p = _player();
      if (_isMounted() && p != null && _canControlPlayback()) unawaited(p.playOrPause());
    };
    receiver.onSeekTo = (position) {
      final p = _player();
      if (_isMounted() && p != null && _canControlPlayback()) unawaited(p.seek(position));
    };
    receiver.onSelectTrack = _selectTrack;

    // Override home to exit the player first. Replacements inherit the base
    // MainScreen callback rather than chaining through the outgoing player.
    _savedOnHome = receiver.playerHomeFallback;
    receiver.onHome = () {
      if (_isMounted()) _onHome();
    };

    // Store provider reference for use in dispose and notify remote
    try {
      _provider = _readProvider();
      _provider!.setHostPlayerActive(true);
    } catch (e) {
      appLogger.d('CompanionRemote provider unavailable', error: e);
    }
    _nowPlayingTimer?.cancel();
    _nowPlayingTimer = Timer.periodic(const Duration(milliseconds: 500), (_) => _publishNowPlaying());
  }

  // Fork, now playing: the phone's mini bar and player screen mirror this.
  Timer? _nowPlayingTimer;
  String? _lastNowPlayingKey;
  DateTime _lastNowPlayingAt = DateTime(0);

  static String _trackLabel(String? title, String? language, String id) {
    final parts = [?title, if (language != null && language != title) language];
    return parts.isEmpty ? 'Track $id' : parts.join(' · ');
  }

  void _selectTrack(String kind, String id) {
    final p = _player();
    if (!_isMounted() || p == null || !_canControlPlayback()) return;
    if (kind == 'audio') {
      final track = p.state.tracks.audio.where((t) => t.id == id).firstOrNull;
      if (track != null) _onSelectAudio(track);
    } else if (kind == 'subtitle') {
      final track = id == SubtitleTrack.off.id
          ? SubtitleTrack.off
          : p.state.tracks.subtitle.where((t) => t.id == id).firstOrNull;
      if (track != null) _onSelectSubtitle(track);
    }
  }

  /// Send the player state when it changed, and as a heartbeat (every second
  /// while playing, every 5 s otherwise) so the phone's clock stays right.
  void _publishNowPlaying() {
    final provider = _provider;
    final p = _player();
    if (provider == null || !provider.isConnected || p == null || !_isMounted()) return;
    final st = p.state;
    final item = _metadata();
    final state = st.buffering ? 'buffering' : (st.playing ? 'playing' : 'paused');
    final marker = CompanionRemoteReceiver.instance.onSkipMarker == null ? null : HostPlayerMarker.current.value;
    final audio = [
      for (final t in st.tracks.audio)
        if (t.id != AudioTrack.auto.id && t.id != AudioTrack.off.id)
          {'id': t.id, 'label': _trackLabel(t.title, t.language, t.id)},
    ];
    final subtitles = [
      for (final t in st.tracks.subtitle)
        if (t.id != SubtitleTrack.auto.id && t.id != SubtitleTrack.off.id)
          {'id': t.id, 'label': _trackLabel(t.title, t.language, t.id)},
    ];
    final isEpisode = item.grandparentTitle != null && item.index != null;
    // Position moves all the time, so it only goes out with the heartbeat;
    // anything else changing goes out at once.
    final key = [
      state,
      item.id,
      st.duration.inSeconds,
      st.track.audio?.id,
      st.track.subtitle?.id,
      audio.length,
      subtitles.length,
      marker,
      _hasNextItem(),
    ].join('|');
    final now = DateTime.now();
    final heartbeat = now.difference(_lastNowPlayingAt) >= Duration(seconds: state == 'playing' ? 1 : 5);
    if (!heartbeat && key == _lastNowPlayingKey) return;
    _lastNowPlayingKey = key;
    _lastNowPlayingAt = now;
    provider.sendCommand(
      RemoteCommandType.nowPlaying,
      data: {
        'state': state,
        'server': item.serverId,
        'id': item.id,
        'title': isEpisode ? item.grandparentTitle : item.title,
        'subtitle': isEpisode
            ? 'S${item.parentIndex ?? 0} · E${item.index} · ${item.title ?? ''}'
            : (item.year?.toString() ?? ''),
        'thumb': isEpisode ? item.thumbPath : (item.artPath ?? item.thumbPath),
        'art': isEpisode ? (item.grandparentArtPath ?? item.artPath) : item.artPath,
        'poster': isEpisode ? (item.grandparentThumbPath ?? item.thumbPath) : item.thumbPath,
        'positionMs': st.position.inMilliseconds,
        'durationMs': st.duration.inMilliseconds,
        'audio': audio,
        'subtitles': subtitles,
        'audioId': st.track.audio?.id,
        'subtitleId': st.track.subtitle?.id ?? SubtitleTrack.off.id,
        'marker': marker,
        'hasNext': _hasNextItem(),
        'hasPrevious': _hasPreviousItem(),
      },
    );
  }

  void _dispatchSeek({required bool forward}) {
    final currentPlayer = _player();
    if (!_isMounted() || currentPlayer == null || !_canControlPlayback()) return;
    // The viewer's configured step, like every other skip source, and the
    // screen coalesces a burst of these into one absolute seek so a remote
    // held on skip cannot dispatch a native seek per repeat.
    _skipByConfiguredStep(forward: forward);
  }

  void _dispatchVolume(double delta) {
    final currentPlayer = _player();
    final controller = _volumeController();
    if (!_isMounted() || currentPlayer == null || controller == null || !controller.ownsPlayer(currentPlayer)) {
      return;
    }
    controller.adjust(delta);
  }

  void _dispatchMute() {
    final currentPlayer = _player();
    final controller = _volumeController();
    if (!_isMounted() || currentPlayer == null || controller == null || !controller.ownsPlayer(currentPlayer)) {
      return;
    }
    controller.toggleMute();
  }

  Future<void> _toggleFullscreen() async {
    if (!PlatformDetector.isDesktopOS()) return;
    await FullscreenStateManager().toggleFullscreen();
  }

  void unbind() {
    final receiver = CompanionRemoteReceiver.instance;
    if (!identical(receiver.playerOwner, this)) {
      _provider = null;
      return;
    }
    receiver.onStop = null;
    receiver.onNextTrack = null;
    receiver.onPreviousTrack = null;
    receiver.onSeekForward = null;
    receiver.onSeekBackward = null;
    receiver.onVolumeUp = null;
    receiver.onVolumeDown = null;
    receiver.onVolumeMute = null;
    receiver.onSubtitles = null;
    receiver.onAudioTracks = null;
    receiver.onFullscreen = null;
    receiver.onPlayPause = null;
    receiver.onSeekTo = null;
    receiver.onSelectTrack = null;
    receiver.onHome = receiver.playerHomeFallback;
    receiver.playerHomeFallback = null;
    receiver.playerOwner = null;
    _savedOnHome = null;

    _nowPlayingTimer?.cancel();
    _nowPlayingTimer = null;
    // Notify only when the active player owner exits.
    if (_provider?.isConnected ?? false) {
      _provider!.sendCommand(RemoteCommandType.nowPlaying, data: {'state': 'stopped'});
    }
    _provider?.setHostPlayerActive(false);
    _provider = null;
  }
}
