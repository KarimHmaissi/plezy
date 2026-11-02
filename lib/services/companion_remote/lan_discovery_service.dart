import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:collection/collection.dart';

import '../../utils/app_logger.dart';
import '../../utils/udp_broadcast_sockets.dart';
import 'remote_auth_context.dart';
import 'remote_auth_service.dart';

/// A host discovered on the LAN via UDP broadcast.
class DiscoveredHost {
  final String authContextId;
  final String clientId;
  final String name;
  final String platform;
  final int port;
  final List<String> ips;
  DateTime lastSeen;

  DiscoveredHost({
    required this.authContextId,
    required this.clientId,
    required this.name,
    required this.platform,
    required this.port,
    required this.ips,
    DateTime? lastSeen,
  }) : lastSeen = lastSeen ?? DateTime.now();

  List<String> get addresses => ips.map((ip) => '$ip:$port').toList();
}

/// UDP-based LAN discovery for companion remote.
///
/// Hosts broadcast authenticated beacons; clients listen and filter
/// by matching Plex home membership.
class LanDiscoveryService {
  static const int defaultDiscoveryPort = 48633;
  static const int _broadcastIntervalSeconds = 3;
  static const int _staleTimeoutSeconds = 10;
  static const int _beaconVersion = 1;

  /// Fork: how often the host checks its beacon sockets still match the
  /// machine's LAN addresses (sleep/wake or a Wi-Fi change kills them).
  static const Duration healthCheckInterval = Duration(seconds: 30);

  /// A beacon tick this late means the machine slept in between.
  static const Duration _wakeGap = Duration(seconds: 15);

  /// UDP port used for both beacon targets and listener binding.
  final int discoveryPort;

  /// The machine's current IPv4 LAN addresses (injectable for tests).
  final Future<List<String>> Function() _listLocalIps;

  LanDiscoveryService({this.discoveryPort = defaultDiscoveryPort, Future<List<String>> Function()? listLocalIps})
    : _listLocalIps = listLocalIps ?? UdpBroadcastSockets.localIPv4Strings;
  // Broadcaster state (host)
  UdpBroadcastSocketSet? _broadcastSockets;
  Timer? _broadcastTimer;
  Timer? _healthTimer;
  DateTime _lastBeaconTick = DateTime.now();
  bool _recovering = false;
  List<RemoteAuthContext> _bcContexts = const [];
  String _bcDeviceName = '';
  String _bcPlatform = '';
  int _bcWsPort = 0;
  List<String> _bcIps = const [];

  /// Called with the new addresses after a recovery changed them, so the
  /// host can update what it shows.
  void Function(List<String> ips)? onAdvertisedIpsChanged;

  /// The addresses the beacon currently advertises.
  List<String> get advertisedIps => _bcIps;

  // Listener state (client)
  RawDatagramSocket? _listenSocket;
  StreamSubscription<RawSocketEvent>? _listenSubscription;
  Timer? _staleCleanupTimer;
  int _listenGeneration = 0;
  final Map<String, DiscoveredHost> _discoveredHosts = {};
  final _hostsController = StreamController<List<DiscoveredHost>>.broadcast();

  bool get isBroadcasting => _broadcastTimer != null;

  /// Whether the listener is currently active.
  bool get isListening => _listenSocket != null;

  // ── Host: Broadcasting ──

  Future<void> startBroadcastingForContexts({
    required List<RemoteAuthContext> contexts,
    required String deviceName,
    required String platform,
    required int wsPort,
    required List<String> ips,
  }) async {
    await stopBroadcasting();
    if (contexts.isEmpty) return;
    _bcContexts = contexts;
    _bcDeviceName = deviceName;
    _bcPlatform = platform;
    _bcWsPort = wsPort;
    _bcIps = List.unmodifiable(ips);

    try {
      // Fork: keep the health check running even when no socket bound yet
      // (e.g. started while the network was down), so it can recover.
      _healthTimer = Timer.periodic(healthCheckInterval, (_) => unawaited(checkBroadcastHealth()));
      _broadcastSockets = await UdpBroadcastSockets.bind()
        ..watchForClose();
      appLogger.d('LanDiscovery: Broadcasting started on port $discoveryPort');

      // Send immediately, then periodically
      _sendAllBeacons();
      _lastBeaconTick = DateTime.now();
      _broadcastTimer = Timer.periodic(const Duration(seconds: _broadcastIntervalSeconds), (_) {
        final now = DateTime.now();
        final gap = now.difference(_lastBeaconTick);
        _lastBeaconTick = now;
        if (gap > _wakeGap) {
          unawaited(checkBroadcastHealth(reason: 'wake (beacon paused ${gap.inSeconds}s)'));
          return;
        }
        _sendAllBeacons();
      });
    } catch (e) {
      appLogger.e('LanDiscovery: Failed to start broadcasting', error: e);
      await stopBroadcasting();
    }
  }

  void _sendAllBeacons() {
    final broadcastSockets = _broadcastSockets;
    if (broadcastSockets == null || broadcastSockets.isEmpty) return;
    for (final context in _bcContexts) {
      _sendBeacon(context, _bcDeviceName, _bcPlatform, _bcWsPort, _bcIps);
    }
    if (broadcastSockets.sendFailures > 0) {
      unawaited(checkBroadcastHealth(reason: 'beacon send failed'));
    }
  }

  /// Fork: rebind the beacon sockets and re-advertise when they no longer
  /// match the machine's LAN addresses, a send failed, or [reason] forces
  /// it (wake). Returns whether it rebound.
  Future<bool> checkBroadcastHealth({String? reason}) async {
    if (_broadcastTimer == null && _healthTimer == null) return false;
    if (_recovering) return false;
    _recovering = true;
    try {
      final current = List<String>.of(await _listLocalIps())..sort();
      final bound = List<String>.of(_broadcastSockets?.boundAddresses ?? const <String>[])..sort();
      final advertised = List<String>.of(_bcIps)..sort();
      final failures = _broadcastSockets?.sendFailures ?? 0;
      String? cause = reason;
      if (cause == null && current.isNotEmpty && !const ListEquality<String>().equals(current, advertised)) {
        cause = 'LAN address changed ($advertised -> $current)';
      }
      if (cause == null && (_broadcastSockets?.closedSockets ?? 0) > 0) cause = 'beacon socket closed by the OS';
      if (cause == null &&
          current.isNotEmpty &&
          !bound.contains('0.0.0.0') &&
          !const ListEquality<String>().equals(current, bound)) {
        cause = 'beacon sockets lost (bound $bound, LAN $current)';
      }
      if (cause == null && failures > 0) cause = 'beacon send failed';
      if (cause == null) return false;
      if (_broadcastTimer == null && _healthTimer == null) return false;

      appLogger.d('LanDiscovery: Re-advertising: $cause');
      await _broadcastSockets?.close();
      _broadcastSockets = await UdpBroadcastSockets.bind()
        ..watchForClose();
      if (current.isNotEmpty && !const ListEquality<String>().equals(current, advertised)) {
        _bcIps = List.unmodifiable(current);
        onAdvertisedIpsChanged?.call(_bcIps);
      }
      _lastBeaconTick = DateTime.now();
      _sendAllBeacons();
      return true;
    } catch (e) {
      appLogger.w('LanDiscovery: Re-advertise failed', error: e);
      return false;
    } finally {
      _recovering = false;
    }
  }

  void _sendBeacon(RemoteAuthContext context, String deviceName, String platform, int wsPort, List<String> ips) {
    final broadcastSockets = _broadcastSockets;
    if (broadcastSockets == null || broadcastSockets.isEmpty) return;

    try {
      final auth = RemoteAuthService.instance;
      final discoveryKey = context.discoveryKey;
      final clientId = context.clientIdentifier;
      final homeHash = auth.computeDiscoveryTag(discoveryKey);

      final beaconHmac = auth.computeBeaconHmac(
        discoveryKey: discoveryKey,
        version: _beaconVersion,
        homeHash: homeHash,
        name: deviceName,
        platform: platform,
        clientId: clientId,
        port: wsPort,
        ips: ips,
      );

      final packet = jsonEncode({
        'app': 'plezy',
        'v': _beaconVersion,
        'homeHash': homeHash,
        'name': deviceName,
        'platform': platform,
        'clientId': clientId,
        'port': wsPort,
        'ips': ips,
        'hmac': beaconHmac,
      });

      final data = utf8.encode(packet);
      broadcastSockets.send(data, UdpBroadcastSockets.limitedBroadcastAddress, discoveryPort);
    } catch (e) {
      appLogger.e('LanDiscovery: Failed to send beacon', error: e);
    }
  }

  Future<void> stopBroadcasting() async {
    _broadcastTimer?.cancel();
    _broadcastTimer = null;
    _healthTimer?.cancel();
    _healthTimer = null;
    await _broadcastSockets?.close();
    _broadcastSockets = null;
    appLogger.d('LanDiscovery: Broadcasting stopped');
  }

  // ── Client: Listening ──

  Stream<List<DiscoveredHost>> startListeningForContexts(List<RemoteAuthContext> contexts) {
    _stopListeningInternal();
    _discoveredHosts.clear();
    final generation = _listenGeneration;

    unawaited(_bindListener(contexts, generation));
    // Periodically remove stale hosts
    _staleCleanupTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      final now = DateTime.now();
      final staleIds = <String>[];
      for (final entry in _discoveredHosts.entries) {
        if (now.difference(entry.value.lastSeen).inSeconds > _staleTimeoutSeconds) {
          staleIds.add(entry.key);
        }
      }
      if (staleIds.isNotEmpty) {
        for (final id in staleIds) {
          _discoveredHosts.remove(id);
        }
        _emitHosts();
      }
    });

    return _hostsController.stream;
  }

  Future<void> _bindListener(List<RemoteAuthContext> contexts, int generation) async {
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        discoveryPort,
        reuseAddress: true,
        reusePort: true,
      );
      if (generation != _listenGeneration) {
        socket.close();
        return;
      }
      _listenSocket = socket;
      appLogger.d('LanDiscovery: Listening on port $discoveryPort');

      _listenSubscription = socket.listenDatagrams(
        (datagram) => _handleDatagram(datagram, contexts),
        debugLabel: 'LanDiscovery listener',
      );
    } catch (e) {
      if (generation == _listenGeneration) {
        appLogger.e('LanDiscovery: Failed to bind listener', error: e);
      }
    }
  }

  void _handleDatagram(Datagram datagram, List<RemoteAuthContext> contexts) {
    try {
      final packet = utf8.decode(datagram.data);
      final json = jsonDecode(packet) as Map<String, dynamic>;

      if (json['app'] != 'plezy') return;

      final version = json['v'] as int? ?? 0;
      final homeHash = json['homeHash'] as String? ?? '';
      final name = json['name'] as String? ?? '';
      final platform = json['platform'] as String? ?? '';
      final clientId = json['clientId'] as String? ?? '';
      final port = json['port'] as int? ?? 0;
      final ips = (json['ips'] as List<dynamic>?)?.cast<String>() ?? [];
      final hmac = json['hmac'] as String? ?? '';

      final auth = RemoteAuthService.instance;
      RemoteAuthContext? matchedContext;
      for (final context in contexts) {
        final discoveryKey = context.discoveryKey;
        if (!auth.verifyBeaconHmac(
          receivedHmac: hmac,
          discoveryKey: discoveryKey,
          version: version,
          homeHash: homeHash,
          name: name,
          platform: platform,
          clientId: clientId,
          port: port,
          ips: ips,
        )) {
          continue;
        }
        if (!auth.matchesDiscoveryTag(homeHash, discoveryKey)) {
          continue;
        }
        matchedContext = context;
        break;
      }
      if (matchedContext == null) {
        return; // Different home
      }

      // Valid beacon from same home. Normalize only after authentication so
      // stored endpoint order matches the canonical HMAC representation.
      final normalizedIps = List<String>.from(ips)..sort();
      final lastSeen = DateTime.now();
      final hostKey = clientId;
      final existing = _discoveredHosts[hostKey];
      if (existing != null) {
        final hostChanged =
            existing.name != name ||
            existing.platform != platform ||
            existing.port != port ||
            !const ListEquality<String>().equals(existing.ips, normalizedIps);
        if (hostChanged) {
          _discoveredHosts[hostKey] = DiscoveredHost(
            authContextId: existing.authContextId,
            clientId: clientId,
            name: name,
            platform: platform,
            port: port,
            ips: normalizedIps,
            lastSeen: lastSeen,
          );
          _emitHosts();
        } else {
          existing.lastSeen = lastSeen;
        }
      } else {
        _discoveredHosts[hostKey] = DiscoveredHost(
          authContextId: matchedContext.id,
          clientId: clientId,
          name: name,
          platform: platform,
          port: port,
          ips: normalizedIps,
          lastSeen: lastSeen,
        );
        appLogger.d('LanDiscovery: Discovered host: $name ($platform) at ${normalizedIps.join(", ")}:$port');
        _emitHosts();
      }
    } catch (e) {
      // Ignore malformed packets
    }
  }

  void _emitHosts() {
    // stopListening() can arrive after dispose(): CompanionRemoteProvider's
    // async crypto-rebuild path tears down the host server on whichever
    // service instance it captured earlier. Emitting into the closed
    // controller threw "Bad state: Cannot add new events after calling
    // close" — the top Dart crash in production.
    if (_hostsController.isClosed) return;
    _hostsController.add(_discoveredHosts.values.toList());
  }

  void stopListening() {
    _stopListeningInternal();
    _discoveredHosts.clear();
    _emitHosts();
  }

  void _stopListeningInternal() {
    ++_listenGeneration;
    _staleCleanupTimer?.cancel();
    _staleCleanupTimer = null;
    _listenSubscription?.cancel();
    _listenSubscription = null;
    _listenSocket?.close();
    _listenSocket = null;
    appLogger.d('LanDiscovery: Listening stopped');
  }

  void dispose() {
    stopBroadcasting();
    stopListening();
    _hostsController.close();
  }
}
