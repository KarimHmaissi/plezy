import 'dart:async';
import 'dart:io';

import 'app_logger.dart';

class UdpBroadcastSocketSet {
  final List<RawDatagramSocket> _sockets;
  final List<StreamSubscription<RawSocketEvent>> _subscriptions = [];

  UdpBroadcastSocketSet._(this._sockets);

  bool get isEmpty => _sockets.isEmpty;

  /// Sends that threw since binding (a dead socket after sleep/wake).
  int sendFailures = 0;

  /// Sockets the OS closed under us (their interface went away).
  int closedSockets = 0;

  /// The local addresses these sockets are bound to.
  List<String> get boundAddresses => [for (final s in _sockets) s.address.address];

  /// Send-only use: count sockets the OS closes (sleep/wake, Wi-Fi drop).
  /// Don't combine with [listen]; a datagram socket takes one listener.
  void watchForClose() {
    for (final socket in _sockets) {
      _subscriptions.add(
        socket.listen(
          (event) {
            if (event == RawSocketEvent.read) {
              while (socket.receive() != null) {}
              return;
            }
            if (event == RawSocketEvent.closed || event == RawSocketEvent.readClosed) closedSockets++;
          },
          onError: (Object _) => closedSockets++,
          onDone: () => closedSockets++,
        ),
      );
    }
  }

  Iterable<RawDatagramSocket> get sockets => _sockets;

  void listen(void Function(Datagram datagram) onDatagram, {required String debugLabel}) {
    for (final socket in _sockets) {
      _subscriptions.add(socket.listenDatagrams(onDatagram, debugLabel: debugLabel));
    }
  }

  void send(List<int> data, InternetAddress address, int port) {
    for (final socket in _sockets) {
      try {
        socket.send(data, address, port);
      } catch (e, st) {
        sendFailures++;
        appLogger.w('UDP broadcast send failed from ${socket.address.address}', error: e, stackTrace: st);
      }
    }
  }

  Future<void> close() async {
    final subscriptions = List<StreamSubscription<RawSocketEvent>>.of(_subscriptions);
    _subscriptions.clear();
    for (final subscription in subscriptions) {
      try {
        await subscription.cancel();
      } catch (e, st) {
        appLogger.w('UDP datagram subscription cancel failed', error: e, stackTrace: st);
      }
    }
    for (final socket in _sockets) {
      socket.close();
    }
  }
}

extension DatagramSocketListen on RawDatagramSocket {
  StreamSubscription<RawSocketEvent> listenDatagrams(
    void Function(Datagram datagram) onDatagram, {
    required String debugLabel,
  }) {
    return listen(
      (event) {
        if (event != RawSocketEvent.read) return;
        Datagram? datagram;
        while ((datagram = receive()) != null) {
          onDatagram(datagram!);
        }
      },
      onError: (Object e, StackTrace st) {
        appLogger.w('$debugLabel datagram socket error', error: e, stackTrace: st);
      },
    );
  }
}

class UdpBroadcastSockets {
  UdpBroadcastSockets._();

  static final InternetAddress limitedBroadcastAddress = InternetAddress('255.255.255.255');

  static Future<UdpBroadcastSocketSet> bind({int port = 0}) async {
    final sockets = <RawDatagramSocket>[];
    for (final address in await _localIPv4Addresses()) {
      final socket = await _tryBind(address, port);
      if (socket != null) sockets.add(socket);
    }

    if (sockets.isEmpty) {
      final socket = await _tryBind(InternetAddress.anyIPv4, port);
      if (socket != null) sockets.add(socket);
    }

    return UdpBroadcastSocketSet._(List.unmodifiable(sockets));
  }

  /// The machine's IPv4 LAN addresses as strings.
  static Future<List<String>> localIPv4Strings() async => [for (final a in await _localIPv4Addresses()) a.address];

  static Future<List<InternetAddress>> _localIPv4Addresses() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLinkLocal: false,
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      final addresses = <InternetAddress>[];
      final seen = <String>{};
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (address.isLoopback || address.type != InternetAddressType.IPv4 || !seen.add(address.address)) continue;
          addresses.add(address);
        }
      }
      return List.unmodifiable(addresses);
    } catch (e, st) {
      appLogger.w('Failed to enumerate IPv4 interfaces for UDP broadcast', error: e, stackTrace: st);
      return const [];
    }
  }

  static Future<RawDatagramSocket?> _tryBind(InternetAddress address, int port) async {
    try {
      final socket = await RawDatagramSocket.bind(address, port);
      socket.broadcastEnabled = true;
      return socket;
    } catch (e, st) {
      appLogger.w('Failed to bind UDP broadcast socket on ${address.address}:$port', error: e, stackTrace: st);
      return null;
    }
  }
}
