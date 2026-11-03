import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../media/media_server_client.dart';
import '../mixins/disposable_change_notifier_mixin.dart';
import '../services/casting/dlna_renderer.dart';
import '../services/casting/google_cast_channel.dart';
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

  CastingTitle withTranscodeSession(String id) => CastingTitle(
    serverId: serverId,
    ratingKey: ratingKey,
    title: title,
    subtitle: subtitle,
    thumbPath: thumbPath,
    sessionIdentifier: sessionIdentifier,
    transcodeSessionId: id,
    item: item,
  );

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
class CastException implements Exception {
  const CastException(this.reason);

  final CastFailure reason;

  @override
  String toString() => 'CastException($reason)';
}

enum CastFailure { notPlex, noStream, loadFailed }

/// Fork: casting from phones to any Google Cast device (Chromecast, Cast
/// TVs, the Shield) or DLNA renderer (most smart TVs, such as LG webOS),
/// with no Plezy needed on the receiver.
///
/// The phone asks the Plex server for a stream the device plays
/// ([PlexClient.buildCastStreamUrl] for Cast's Default Media Receiver,
/// [PlexClient.buildDlnaStream] for DLNA), hands it over, and reports the
/// device's progress to Plex as this device's timeline so resume points,
/// Continue Watching and watched state stay right.
class CastProvider with ChangeNotifier, DisposableChangeNotifierMixin {
  CastProvider({required this._clientFor, GoogleCastChannel? channel, DlnaDiscovery? dlnaDiscovery})
    : _channel = channel ?? GoogleCastChannel(),
      _dlnaDiscovery = dlnaDiscovery ?? DlnaDiscovery() {
    unawaited(_init());
  }

  final MediaServerClient? Function(String serverId) _clientFor;
  final GoogleCastChannel _channel;
  final DlnaDiscovery _dlnaDiscovery;
  final _subscriptions = <StreamSubscription<Object?>>[];

  /// How often a playing (or paused) cast is reported to Plex.
  static const reportInterval = Duration(seconds: 10);

  /// How often a DLNA renderer is asked where it is.
  static const dlnaPollInterval = Duration(seconds: 1);

  bool _googleAvailable = false;

  /// DLNA works from any Android device on the LAN (iOS would need the
  /// multicast entitlement first).
  static final bool _dlnaAvailable = Platform.isAndroid;

  /// Whether this device can cast at all.
  bool get available => _googleAvailable || _dlnaAvailable;

  List<CastRoute> _googleRoutes = const [];
  List<CastRoute> _dlnaRoutes = const [];

  /// Every device found, Google Cast first.
  List<CastRoute> get routes => [..._googleRoutes, ..._dlnaRoutes];

  CastSessionState _googleState = CastSessionState.none;
  String? _googleDevice;

  /// The DLNA renderer Play goes to, when one is picked. DLNA has no
  /// session: picking it is connecting.
  DlnaPlayer? _dlna;

  CastKind? get connectedKind =>
      _dlna != null ? CastKind.dlna : (_googleState == CastSessionState.connected ? CastKind.googleCast : null);

  CastSessionState get sessionState => _dlna != null ? CastSessionState.connected : _googleState;
  bool get isConnected => connectedKind != null;
  String? get deviceName => _dlna?.renderer.name ?? _googleDevice;

  CastMediaStatus? _status;

  /// The device's player while a title of ours is loaded, else null.
  CastMediaStatus? get status => _title == null ? null : _status;

  CastingTitle? _title;
  CastingTitle? get title => _title;

  /// True between asking the server for a stream and the device loading it.
  bool _starting = false;
  bool get starting => _starting;

  /// Sessions already settled with Plex, which the receiver may still
  /// describe (idle, with the same custom data) and must not be adopted again.
  final _ended = <String>{};

  DateTime? _lastReport;
  String? _lastReportedState;

  Future<void> _init() async {
    if (_dlnaAvailable) {
      _subscriptions.add(_dlnaDiscovery.devices.listen(_onDlnaDevices));
    }
    _googleAvailable = await _channel.init();
    if (isDisposed) return;
    if (_googleAvailable) {
      _subscriptions
        ..add(_channel.routes.listen(_onRoutes))
        ..add(_channel.sessions.listen(_onSession))
        ..add(_channel.media.listen(_onGoogleMedia));
      await _channel.refreshState();
    }
    safeNotifyListeners();
  }

  @override
  void dispose() {
    for (final sub in _subscriptions) {
      unawaited(sub.cancel());
    }
    _dlnaPoll?.cancel();
    _dlnaDiscovery.stop();
    super.dispose();
  }

  // Devices and session

  Future<void> startDiscovery() async {
    if (_googleAvailable) await _channel.startDiscovery();
    if (_dlnaAvailable) await _dlnaDiscovery.start();
  }

  Future<void> stopDiscovery() async {
    if (_googleAvailable) await _channel.stopDiscovery();
    _dlnaDiscovery.stop();
  }

  Future<void> connect(CastRoute route) async {
    switch (route.kind) {
      case CastKind.googleCast:
        if (_dlna != null) await _leaveDlna();
        await _channel.selectRoute(route.id);
      case CastKind.dlna:
        final renderer = _dlnaDiscovery.current.where((r) => r.udn == route.id).firstOrNull;
        if (renderer == null) return;
        if (_dlna != null) await _leaveDlna();
        if (_googleState != CastSessionState.none) await _channel.endSession(stopCasting: true);
        _dlna = DlnaPlayer(renderer);
        _publishDlnaRoutes();
        safeNotifyListeners();
    }
  }

  /// Stop casting and leave the device.
  Future<void> disconnect() async {
    if (_dlna != null) {
      await _leaveDlna();
      safeNotifyListeners();
      return;
    }
    await _finish(_status?.positionMs);
    await _channel.endSession(stopCasting: true);
  }

  void _onRoutes(List<CastRoute> routes) {
    _googleRoutes = routes;
    safeNotifyListeners();
  }

  void _onDlnaDevices(List<DlnaRenderer> _) {
    _publishDlnaRoutes();
    safeNotifyListeners();
  }

  void _publishDlnaRoutes() {
    _dlnaRoutes = [
      for (final r in _dlnaDiscovery.current)
        CastRoute(
          id: r.udn,
          name: r.name,
          description: 'DLNA',
          kind: CastKind.dlna,
          selected: _dlna?.renderer.udn == r.udn,
        ),
    ];
  }

  void _onSession(({CastSessionState state, String? device}) event) {
    final wasConnected = _googleState == CastSessionState.connected;
    _googleState = event.state;
    if (event.device != null) _googleDevice = event.device;
    if (event.state == CastSessionState.none && wasConnected && _dlna == null) {
      // The device went away (or someone else took it over): settle Plex.
      unawaited(_finish(_status?.positionMs));
    }
    safeNotifyListeners();
  }

  void _onGoogleMedia(CastMediaStatus? status) {
    if (_dlna != null) return;
    _onMedia(status);
  }

  void _onMedia(CastMediaStatus? status) {
    _status = status;
    if (status == null) {
      safeNotifyListeners();
      return;
    }
    // Rejoined after a restart: the receiver tells us what is playing.
    if (_title == null && !_starting && !status.idle && _dlna == null) {
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

  /// Cast [item] from [start] (or the beginning). Throws [CastException]
  /// when it cannot.
  Future<void> play(MediaItem item, {Duration start = Duration.zero}) async {
    final serverId = item.serverId;
    final client = serverId == null ? null : _clientFor(serverId);
    if (client is! PlexClient || item is! PlexMediaItem) {
      throw const CastException(CastFailure.notPlex);
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
      final image = title.thumbPath == null ? null : client.thumbnailUrl(title.thumbPath, width: 640, height: 960);
      final dlna = _dlna;
      if (dlna != null) {
        await _loadDlna(dlna, client, title, start: start, imageUrl: image);
      } else {
        await _loadGoogle(client, title, start: start, imageUrl: image);
      }
      _title = title;
      _lastReport = null;
      _lastReportedState = null;
    } finally {
      _starting = false;
      safeNotifyListeners();
    }
  }

  Future<void> _loadGoogle(PlexClient client, CastingTitle title, {required Duration start, String? imageUrl}) async {
    final url = await client.buildCastStreamUrl(
      ratingKey: title.ratingKey,
      sessionIdentifier: title.sessionIdentifier,
      transcodeSessionId: title.transcodeSessionId,
    );
    if (url == null) throw const CastException(CastFailure.noStream);
    try {
      await _channel.load(
        url: url,
        title: title.title,
        subtitle: title.subtitle,
        imageUrl: imageUrl == null || imageUrl.isEmpty ? null : imageUrl,
        episode: title.item?.kind == MediaKind.episode,
        durationMs: title.item?.durationMs,
        startMs: start.inMilliseconds,
        customData: title.toCustomData(),
      );
    } catch (e) {
      appLogger.w('Google Cast load failed', error: e);
      unawaited(client.stopTranscodeSession(title.transcodeSessionId));
      throw const CastException(CastFailure.loadFailed);
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
    final pause = status.playing || status.state == 'buffering';
    final dlna = _dlna;
    if (dlna != null) {
      await (pause ? dlna.pause() : dlna.play());
      await _pollDlna();
      return;
    }
    await (pause ? _channel.pause() : _channel.play());
  }

  Future<void> seek(Duration position) async {
    if (_dlna != null) return _seekDlna(position);
    await _channel.seek(position);
  }

  Future<void> seekBy(Duration delta) async {
    final status = _status;
    if (status == null) return;
    var target = status.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (status.durationMs > 0 && target > status.duration) target = status.duration;
    await seek(target);
  }

  /// Stop the title but stay connected to the device.
  Future<void> stop() async {
    final position = _status?.positionMs;
    final dlna = _dlna;
    if (dlna != null) {
      _stopDlnaPoll();
      try {
        await dlna.stop();
      } catch (e) {
        appLogger.d('DLNA stop failed', error: e);
      }
    } else {
      await _channel.stop();
    }
    await _finish(position);
  }

  // DLNA

  Timer? _dlnaPoll;

  /// Whether the DLNA stream is the file itself (seekable on the renderer)
  /// rather than a live transcode (a seek restarts it at an offset).
  bool _dlnaSeekable = true;

  /// Where a transcoded DLNA stream starts in the title: the renderer's own
  /// clock counts from zero.
  Duration _dlnaBase = Duration.zero;

  /// A resume point to seek to once a seekable stream is playing.
  Duration? _dlnaPendingSeek;

  bool _dlnaSeenPlaying = false;
  Duration _dlnaLastPosition = Duration.zero;
  bool _dlnaPolling = false;

  Future<void> _loadDlna(
    DlnaPlayer dlna,
    PlexClient client,
    CastingTitle title, {
    required Duration start,
    String? imageUrl,
    bool allowDirect = true,
  }) async {
    _stopDlnaPoll();
    final stream = await client.buildDlnaStream(
      ratingKey: title.ratingKey,
      acceptsMime: dlna.renderer.accepts,
      sessionIdentifier: title.sessionIdentifier,
      transcodeSessionId: title.transcodeSessionId,
      offset: start,
      allowDirect: allowDirect,
    );
    if (stream == null) throw const CastException(CastFailure.noStream);
    try {
      await dlna.load(
        url: stream.url,
        mime: stream.mime,
        title: title.subtitle == null ? title.title : '${title.title} · ${title.subtitle}',
        imageUrl: imageUrl == null || imageUrl.isEmpty ? null : imageUrl,
        durationMs: title.item?.durationMs,
        seekable: stream.seekable,
      );
    } catch (e) {
      appLogger.w('DLNA load failed', error: e);
      if (!stream.seekable) unawaited(client.stopTranscodeSession(title.transcodeSessionId));
      throw const CastException(CastFailure.loadFailed);
    }
    _dlnaSeekable = stream.seekable;
    _dlnaBase = stream.seekable ? Duration.zero : start;
    _dlnaPendingSeek = stream.seekable && start > Duration.zero ? start : null;
    _dlnaSeenPlaying = false;
    _dlnaLastPosition = start;
    _dlnaPoll = Timer.periodic(dlnaPollInterval, (_) => unawaited(_pollDlna()));
  }

  void _stopDlnaPoll() {
    _dlnaPoll?.cancel();
    _dlnaPoll = null;
  }

  Future<void> _pollDlna() async {
    final dlna = _dlna;
    final title = _title;
    if (dlna == null || title == null || _dlnaPolling) return;
    _dlnaPolling = true;
    try {
      final transport = await dlna.transportState();
      final info = await dlna.position();
      if (!identical(_dlna, dlna) || !identical(_title, title)) return;
      final durationMs = title.item?.durationMs ?? info.duration.inMilliseconds;
      final playing = transport == 'PLAYING';
      if (playing) {
        _dlnaSeenPlaying = true;
        final pending = _dlnaPendingSeek;
        if (pending != null) {
          _dlnaPendingSeek = null;
          await dlna.seek(pending);
          return;
        }
      }
      final position = _dlnaBase + info.position;
      final ended = _dlnaSeenPlaying && (transport == 'STOPPED' || transport == 'NO_MEDIA_PRESENT');
      if (!ended && info.position > Duration.zero) _dlnaLastPosition = position;
      String? idleReason;
      if (ended) {
        // DLNA has no "finished": call it finished when it stopped near the end.
        final nearEnd = durationMs > 0 && _dlnaLastPosition.inMilliseconds >= durationMs * 0.95;
        idleReason = nearEnd ? 'finished' : 'cancelled';
        _stopDlnaPoll();
      }
      _onMedia(
        CastMediaStatus(
          state: switch (transport) {
            'PLAYING' => 'playing',
            'PAUSED_PLAYBACK' => 'paused',
            'TRANSITIONING' => 'buffering',
            _ when !_dlnaSeenPlaying => 'buffering',
            _ => 'idle',
          },
          positionMs: (ended ? _dlnaLastPosition : position).inMilliseconds,
          durationMs: durationMs,
          idleReason: idleReason,
          customData: {'session': title.sessionIdentifier},
        ),
      );
    } catch (e) {
      appLogger.d('DLNA poll failed', error: e);
    } finally {
      _dlnaPolling = false;
    }
  }

  Future<void> _seekDlna(Duration position) async {
    final dlna = _dlna;
    final title = _title;
    if (dlna == null || title == null) return;
    if (_dlnaSeekable) {
      await dlna.seek(position);
      await _pollDlna();
      return;
    }
    // A live transcode can't seek: start a new one at the new point.
    final client = _clientForTitle(title);
    if (client == null) return;
    unawaited(client.stopTranscodeSession(title.transcodeSessionId));
    final next = title.withTranscodeSession(const Uuid().v4());
    _title = next;
    _starting = true;
    safeNotifyListeners();
    try {
      await _loadDlna(dlna, client, next, start: position, allowDirect: false);
    } finally {
      _starting = false;
      safeNotifyListeners();
    }
  }

  /// Leave the DLNA renderer, stopping what we played on it.
  Future<void> _leaveDlna() async {
    final dlna = _dlna;
    if (dlna == null) return;
    _stopDlnaPoll();
    final position = _status?.positionMs;
    if (_title != null) {
      try {
        await dlna.stop();
      } catch (_) {}
    }
    await _finish(position);
    _dlna = null;
    _publishDlnaRoutes();
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
      appLogger.d('Cast: timeline report failed', error: e);
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
