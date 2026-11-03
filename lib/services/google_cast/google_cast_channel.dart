import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../utils/app_logger.dart';

/// A Cast device found on the network.
class CastRoute {
  const CastRoute({required this.id, required this.name, this.description = '', this.selected = false});

  final String id;
  final String name;
  final String description;
  final bool selected;

  static CastRoute fromMap(Map<dynamic, dynamic> map) => CastRoute(
    id: map['id'] as String,
    name: map['name'] as String? ?? '',
    description: map['description'] as String? ?? '',
    selected: map['selected'] == true,
  );
}

enum CastSessionState { none, connecting, connected }

/// The receiver's player, as last reported, with the position carried
/// forward between reports so a clock can run smoothly.
class CastMediaStatus {
  CastMediaStatus({
    required this.state,
    required this.positionMs,
    required this.durationMs,
    this.idleReason,
    this.customData,
  }) : receivedAt = DateTime.now();

  /// playing, paused, buffering, idle or unknown.
  final String state;
  final int positionMs;
  final int durationMs;

  /// finished, cancelled, interrupted or error, when [state] is idle.
  final String? idleReason;

  /// What the load carried (see `GoogleCastProvider`), so a session the app
  /// rejoined after a restart still knows its title.
  final Map<String, dynamic>? customData;
  final DateTime receivedAt;

  bool get playing => state == 'playing';
  bool get idle => state == 'idle';

  Duration get duration => Duration(milliseconds: durationMs);

  Duration get position {
    final base = Duration(milliseconds: positionMs);
    final now = playing ? base + DateTime.now().difference(receivedAt) : base;
    return durationMs > 0 && now > duration ? duration : now;
  }

  double get progress => durationMs <= 0 ? 0 : (position.inMilliseconds / durationMs).clamp(0.0, 1.0);

  static CastMediaStatus fromMap(Map<dynamic, dynamic> map) {
    Map<String, dynamic>? custom;
    final raw = map['customData'];
    if (raw is String && raw.isNotEmpty) {
      try {
        custom = (jsonDecode(raw) as Map).cast<String, dynamic>();
      } catch (_) {}
    }
    return CastMediaStatus(
      state: map['state'] as String? ?? 'unknown',
      positionMs: (map['positionMs'] as num?)?.toInt() ?? 0,
      durationMs: (map['durationMs'] as num?)?.toInt() ?? 0,
      idleReason: map['idleReason'] as String?,
      customData: custom,
    );
  }
}

/// Fork: Dart side of the Android Google Cast sender (`GoogleCastChannel.kt`).
/// Android phones only; [init] answers false everywhere else.
class GoogleCastChannel {
  GoogleCastChannel() {
    if (Platform.isAndroid) _channel.setMethodCallHandler(_onNativeCall);
  }

  static const _channel = MethodChannel('com.plezy/google_cast');

  final _routes = StreamController<List<CastRoute>>.broadcast();
  final _sessions = StreamController<({CastSessionState state, String? device})>.broadcast();
  final _media = StreamController<CastMediaStatus?>.broadcast();

  Stream<List<CastRoute>> get routes => _routes.stream;
  Stream<({CastSessionState state, String? device})> get sessions => _sessions.stream;
  Stream<CastMediaStatus?> get media => _media.stream;

  Future<bool> init() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('init') ?? false;
    } on PlatformException catch (e) {
      appLogger.w('Google Cast unavailable', error: e);
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onRoutes':
        _routes.add([for (final r in (call.arguments as List? ?? const [])) CastRoute.fromMap(r as Map)]);
      case 'onSession':
        final args = call.arguments as Map;
        final state = switch (args['state']) {
          'connected' => CastSessionState.connected,
          'connecting' => CastSessionState.connecting,
          _ => CastSessionState.none,
        };
        _sessions.add((state: state, device: args['device'] as String?));
      case 'onMedia':
        final args = call.arguments;
        _media.add(args is Map ? CastMediaStatus.fromMap(args) : null);
    }
  }

  Future<void> startDiscovery() => _channel.invokeMethod('startDiscovery');
  Future<void> stopDiscovery() => _channel.invokeMethod('stopDiscovery');
  Future<void> selectRoute(String id) => _channel.invokeMethod('selectRoute', {'id': id});
  Future<void> endSession({bool stopCasting = true}) =>
      _channel.invokeMethod('endSession', {'stopCasting': stopCasting});

  /// Ask native to resend the session and media state.
  Future<void> refreshState() => _channel.invokeMethod('getState');

  Future<void> load({
    required String url,
    required String title,
    String? subtitle,
    String? imageUrl,
    bool episode = false,
    int? durationMs,
    int startMs = 0,
    Map<String, Object?>? customData,
  }) => _channel.invokeMethod('load', {
    'url': url,
    'title': title,
    'subtitle': ?subtitle,
    'imageUrl': ?imageUrl,
    'episode': episode,
    'durationMs': ?durationMs,
    'startMs': startMs,
    'customData': ?customData,
  });

  Future<void> play() => _channel.invokeMethod('play');
  Future<void> pause() => _channel.invokeMethod('pause');
  Future<void> stop() => _channel.invokeMethod('stop');
  Future<void> seek(Duration position) => _channel.invokeMethod('seek', {'positionMs': position.inMilliseconds});
}
