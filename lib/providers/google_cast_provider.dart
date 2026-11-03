import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../media/media_server_client.dart';
import '../mixins/disposable_change_notifier_mixin.dart';
import '../services/google_cast/google_cast_channel.dart';
import '../services/plex_client.dart';
import '../utils/app_logger.dart';
import '../utils/watch_state_notifier.dart';

/// What is casting, enough to report it to Plex and to show it. Travels to
/// the receiver as the load's custom data, so a session rejoined after the
/// app restarted carries on reporting.
class CastingTitle {
  const CastingTitle({
    required this.serverId,
    required this.ratingKey,
    required this.title,
    this.subtitle,
    this.thumbPath,
    required this.sessionIdentifier,
    required this.transcodeSessionId,
    this.item,
  });

  final String serverId;
  final String ratingKey;
  final String title;
  final String? subtitle;
  final String? thumbPath;

  /// `X-Plex-Session-Identifier` and the transcoder's `session`, shared by
  /// the stream URL and the timeline reports so the server ties them up.
  final String sessionIdentifier;
  final String transcodeSessionId;

  /// The item played, when this app started the cast (not after a rejoin).
  final MediaItem? item;

  Map<String, Object?> toCustomData() => {
    'plezy': 1,
    'server': serverId,
    'id': ratingKey,
    'title': title,
    'subtitle': ?subtitle,
    'thumb': ?thumbPath,
    'session': sessionIdentifier,
    'transcodeSession': transcodeSessionId,
  };

  static CastingTitle? fromCustomData(Map<String, dynamic>? data) {
    if (data == null || data['plezy'] != 1) return null;
    final server = data['server'], id = data['id'], session = data['session'], transcode = data['transcodeSession'];
    if (server is! String || id is! String || session is! String || transcode is! String) return null;
    return CastingTitle(
      serverId: server,
      ratingKey: id,
      title: data['title'] as String? ?? '',
      subtitle: data['subtitle'] as String?,
      thumbPath: data['thumb'] as String?,
      sessionIdentifier: session,
      transcodeSessionId: transcode,
    );
  }
}

/// Why a cast could not start, for the caller to show.
class GoogleCastException implements Exception {
  const GoogleCastException(this.reason);

  final GoogleCastFailure reason;

  @override
  String toString() => 'GoogleCastException($reason)';
}

enum GoogleCastFailure { notPlex, noStream, loadFailed }

/// Fork: Google Cast from phones to any Cast device (Chromecast, Cast TVs,
/// the Shield), with no Plezy needed on the receiver.
///
/// The phone asks the Plex server for a stream the Default Media Receiver
/// plays ([PlexClient.buildCastStreamUrl]), loads it there, and reports the
/// receiver's progress to Plex as this device's timeline so resume points,
/// Continue Watching and watched state stay right.
class GoogleCastProvider with ChangeNotifier, DisposableChangeNotifierMixin {
  GoogleCastProvider({required this._clientFor, GoogleCastChannel? channel})
    : _channel = channel ?? GoogleCastChannel() {
    unawaited(_init());
  }

  final MediaServerClient? Function(String serverId) _clientFor;
  final GoogleCastChannel _channel;
  final _subscriptions = <StreamSubscription<Object?>>[];

  /// How often a playing (or paused) cast is reported to Plex.
  static const reportInterval = Duration(seconds: 10);

  bool _available = false;

  /// Whether this device can cast (Android phone with Google Play services).
  bool get available => _available;

  List<CastRoute> _routes = const [];
  List<CastRoute> get routes => _routes;

  CastSessionState _sessionState = CastSessionState.none;
  CastSessionState get sessionState => _sessionState;
  bool get isConnected => _sessionState == CastSessionState.connected;

  String? _deviceName;
  String? get deviceName => _deviceName;

  CastMediaStatus? _status;

  /// The receiver's player while a title of ours is loaded, else null.
  CastMediaStatus? get status => _title == null ? null : _status;

  CastingTitle? _title;
  CastingTitle? get title => _title;

  /// True between asking the server for a stream and the receiver loading it.
  bool _starting = false;
  bool get starting => _starting;

  /// Sessions already settled with Plex, which the receiver may still
  /// describe (idle, with the same custom data) and must not be adopted again.
  final _ended = <String>{};

  DateTime? _lastReport;
  String? _lastReportedState;

  Future<void> _init() async {
    _available = await _channel.init();
    if (!_available || isDisposed) return;
    _subscriptions
      ..add(_channel.routes.listen(_onRoutes))
      ..add(_channel.sessions.listen(_onSession))
      ..add(_channel.media.listen(_onMedia));
    await _channel.refreshState();
    safeNotifyListeners();
  }

  @override
  void dispose() {
    for (final sub in _subscriptions) {
      unawaited(sub.cancel());
    }
    super.dispose();
  }

  // Devices and session

  Future<void> startDiscovery() async {
    if (_available) await _channel.startDiscovery();
  }

  Future<void> stopDiscovery() async {
    if (_available) await _channel.stopDiscovery();
  }

  Future<void> connect(CastRoute route) => _channel.selectRoute(route.id);

  /// Stop casting and leave the device.
  Future<void> disconnect() async {
    await _finish(_status?.positionMs);
    await _channel.endSession(stopCasting: true);
  }

  void _onRoutes(List<CastRoute> routes) {
    _routes = routes;
    safeNotifyListeners();
  }

  void _onSession(({CastSessionState state, String? device}) event) {
    final wasConnected = isConnected;
    _sessionState = event.state;
    if (event.device != null) _deviceName = event.device;
    if (event.state == CastSessionState.none && wasConnected) {
      // The device went away (or someone else took it over): settle Plex.
      unawaited(_finish(_status?.positionMs));
    }
    safeNotifyListeners();
  }

  void _onMedia(CastMediaStatus? status) {
    _status = status;
    if (status == null) {
      safeNotifyListeners();
      return;
    }
    // Rejoined after a restart: the receiver tells us what is playing.
    if (_title == null && !_starting && !status.idle) {
      final rejoined = CastingTitle.fromCustomData(status.customData);
      if (rejoined != null && !_ended.contains(rejoined.sessionIdentifier)) _title = rejoined;
    }
    final title = _title;
    if (title != null && status.customData?['session'] == title.sessionIdentifier) {
      if (status.idle && status.idleReason != null) {
        final finished = status.idleReason == 'finished';
        unawaited(_finish(finished ? status.durationMs : status.positionMs));
      } else {
        _maybeReport(status);
      }
    }
    safeNotifyListeners();
  }

  // Playback

  /// Cast [item] from [start] (or the beginning). Throws
  /// [GoogleCastException] when it cannot.
  Future<void> play(MediaItem item, {Duration start = Duration.zero}) async {
    final serverId = item.serverId;
    final client = serverId == null ? null : _clientFor(serverId);
    if (client is! PlexClient || item is! PlexMediaItem) {
      throw const GoogleCastException(GoogleCastFailure.notPlex);
    }
    await _finish(_status?.positionMs);
    _starting = true;
    safeNotifyListeners();
    try {
      final title = CastingTitle(
        serverId: serverId!,
        ratingKey: item.id,
        title: item.displayTitle,
        subtitle: item.kind == MediaKind.episode ? _episodeLine(item) : item.year?.toString(),
        thumbPath: item.kind == MediaKind.episode ? (item.thumbPath ?? item.grandparentThumbPath) : item.thumbPath,
        sessionIdentifier: const Uuid().v4(),
        transcodeSessionId: const Uuid().v4(),
        item: item,
      );
      final url = await client.buildCastStreamUrl(
        ratingKey: item.id,
        sessionIdentifier: title.sessionIdentifier,
        transcodeSessionId: title.transcodeSessionId,
      );
      if (url == null) throw const GoogleCastException(GoogleCastFailure.noStream);
      final image = title.thumbPath == null ? null : client.thumbnailUrl(title.thumbPath, width: 640, height: 960);
      try {
        await _channel.load(
          url: url,
          title: title.title,
          subtitle: title.subtitle,
          imageUrl: image == null || image.isEmpty ? null : image,
          episode: item.kind == MediaKind.episode,
          durationMs: item.durationMs,
          startMs: start.inMilliseconds,
          customData: title.toCustomData(),
        );
      } catch (e) {
        appLogger.w('Google Cast load failed', error: e);
        unawaited(client.stopTranscodeSession(title.transcodeSessionId));
        throw const GoogleCastException(GoogleCastFailure.loadFailed);
      }
      _title = title;
      _lastReport = null;
      _lastReportedState = null;
    } finally {
      _starting = false;
      safeNotifyListeners();
    }
  }

  static String? _episodeLine(MediaItem item) {
    final season = item.parentIndex, episode = item.index;
    final code = season != null && episode != null ? 'S$season · E$episode' : null;
    return [?code, ?item.title].join(' — ');
  }

  Future<void> togglePlay() async {
    final status = _status;
    if (status == null) return;
    await (status.playing || status.state == 'buffering' ? _channel.pause() : _channel.play());
  }

  Future<void> seek(Duration position) => _channel.seek(position);

  Future<void> seekBy(Duration delta) async {
    final status = _status;
    if (status == null) return;
    var target = status.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (status.durationMs > 0 && target > status.duration) target = status.duration;
    await _channel.seek(target);
  }

  /// Stop the title but stay connected to the device.
  Future<void> stop() async {
    final position = _status?.positionMs;
    await _channel.stop();
    await _finish(position);
  }

  // Reporting to Plex

  PlexClient? _clientForTitle(CastingTitle title) {
    final client = _clientFor(title.serverId);
    return client is PlexClient ? client : null;
  }

  void _maybeReport(CastMediaStatus status) {
    final state = switch (status.state) {
      'playing' => 'playing',
      'paused' => 'paused',
      'buffering' => 'buffering',
      _ => null,
    };
    if (state == null) return;
    final now = DateTime.now();
    final due = _lastReport == null || now.difference(_lastReport!) >= reportInterval;
    if (!due && state == _lastReportedState) return;
    _lastReport = now;
    _lastReportedState = state;
    unawaited(_report(_title!, state: state, positionMs: status.positionMs, durationMs: status.durationMs));
  }

  Future<void> _report(
    CastingTitle title, {
    required String state,
    required int positionMs,
    required int durationMs,
  }) async {
    final client = _clientForTitle(title);
    if (client == null) return;
    try {
      await client.updateProgress(
        title.ratingKey,
        time: positionMs,
        state: state,
        duration: durationMs > 0 ? durationMs : null,
        sessionIdentifier: title.sessionIdentifier,
      );
      if (state == 'paused') await client.pingTranscodeSession(title.transcodeSessionId);
    } catch (e) {
      appLogger.d('Google Cast: timeline report failed', error: e);
    }
  }

  /// The title ended (finished, stopped, replaced or the device left): the
  /// final timeline report, end the server's transcode, and let the app's
  /// lists pick up the new resume point.
  Future<void> _finish(int? positionMs) async {
    final title = _title;
    if (title == null) return;
    _title = null;
    _ended.add(title.sessionIdentifier);
    final durationMs = _status?.durationMs ?? title.item?.durationMs ?? 0;
    final position = positionMs ?? 0;
    safeNotifyListeners();
    await _report(title, state: 'stopped', positionMs: position, durationMs: durationMs);
    await _clientForTitle(title)?.stopTranscodeSession(title.transcodeSessionId);
    final item = title.item;
    if (item != null && durationMs > 0) {
      WatchStateNotifier().notifyProgress(
        item: item,
        viewOffset: position,
        duration: durationMs,
        serverAcknowledged: true,
      );
    }
  }
}
