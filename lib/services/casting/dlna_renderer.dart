import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../../utils/app_logger.dart';

/// Fork: a DLNA / UPnP AV media renderer that plays video (most smart TVs,
/// including LG webOS, Samsung and Sony, and many AV receivers).
class DlnaRenderer {
  const DlnaRenderer({
    required this.udn,
    required this.name,
    required this.model,
    required this.avTransportUrl,
    required this.sinkMimeTypes,
  });

  /// The device's unique id (`uuid:…`).
  final String udn;
  final String name;
  final String model;
  final Uri avTransportUrl;

  /// MIME types the renderer says it plays over HTTP (ConnectionManager's
  /// sink protocol info), lower-cased.
  final Set<String> sinkMimeTypes;

  bool accepts(String mime) => sinkMimeTypes.contains(mime) || sinkMimeTypes.contains('*');
}

/// Finds video renderers on the LAN with SSDP: an M-SEARCH for
/// `MediaRenderer:1`, then each answer's device description and its
/// ConnectionManager sink list. Renderers that list no video type
/// (speakers, HEOS) are left out.
class DlnaDiscovery {
  static const _searchTarget = 'urn:schemas-upnp-org:device:MediaRenderer:1';
  static const _avTransport = 'urn:schemas-upnp-org:service:AVTransport:1';
  static const _connectionManager = 'urn:schemas-upnp-org:service:ConnectionManager:1';
  static final _multicast = InternetAddress('239.255.255.250');

  final _devices = StreamController<List<DlnaRenderer>>.broadcast();
  final _found = <String, DlnaRenderer>{};
  final _probing = <String>{};
  RawDatagramSocket? _socket;
  Timer? _searchTimer;

  Stream<List<DlnaRenderer>> get devices => _devices.stream;
  List<DlnaRenderer> get current => _found.values.toList();

  Future<void> start() async {
    if (_socket != null) return;
    try {
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.multicastHops = 2;
      _socket = socket;
      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        Datagram? datagram;
        while ((datagram = socket.receive()) != null) {
          _onResponse(utf8.decode(datagram!.data, allowMalformed: true));
        }
      });
      _search();
      // Devices miss single packets; ask again while the picker is open.
      _searchTimer = Timer.periodic(const Duration(seconds: 4), (_) => _search());
    } catch (e) {
      appLogger.w('DLNA discovery unavailable', error: e);
    }
  }

  void stop() {
    _searchTimer?.cancel();
    _searchTimer = null;
    _socket?.close();
    _socket = null;
  }

  void _search() {
    final message = utf8.encode(
      'M-SEARCH * HTTP/1.1\r\n'
      'HOST: 239.255.255.250:1900\r\n'
      'MAN: "ssdp:discover"\r\n'
      'MX: 2\r\n'
      'ST: $_searchTarget\r\n\r\n',
    );
    try {
      _socket?.send(message, _multicast, 1900);
    } catch (e) {
      appLogger.d('DLNA M-SEARCH failed', error: e);
    }
  }

  void _onResponse(String response) {
    String? location;
    for (final line in response.split('\r\n')) {
      final colon = line.indexOf(':');
      if (colon > 0 && line.substring(0, colon).trim().toLowerCase() == 'location') {
        location = line.substring(colon + 1).trim();
      }
    }
    if (location == null || _probing.contains(location)) return;
    _probing.add(location);
    unawaited(_probe(location));
  }

  Future<void> _probe(String location) async {
    try {
      final base = Uri.parse(location);
      final description = await http.get(base).timeout(const Duration(seconds: 4));
      if (description.statusCode != 200) return;
      final doc = XmlDocument.parse(utf8.decode(description.bodyBytes, allowMalformed: true));
      final urlBase = doc.findAllElements('URLBase').firstOrNull?.innerText.trim();
      final root = urlBase == null || urlBase.isEmpty ? base : Uri.parse(urlBase);
      for (final device in doc.findAllElements('device')) {
        final services = {
          for (final s in device.findElements('serviceList').expand((l) => l.findElements('service')))
            s.getElement('serviceType')?.innerText.trim() ?? '': s.getElement('controlURL')?.innerText.trim() ?? '',
        };
        final avControl = services[_avTransport];
        final cmControl = services[_connectionManager];
        final udn = device.getElement('UDN')?.innerText.trim();
        if (avControl == null || avControl.isEmpty || udn == null || _found.containsKey(udn)) continue;
        final sinks = cmControl == null ? <String>{} : await _sinkMimeTypes(root.resolve(cmControl));
        if (!sinks.any((m) => m.startsWith('video/'))) continue;
        _found[udn] = DlnaRenderer(
          udn: udn,
          name: device.getElement('friendlyName')?.innerText.trim() ?? 'TV',
          model: device.getElement('modelName')?.innerText.trim() ?? '',
          avTransportUrl: root.resolve(avControl),
          sinkMimeTypes: sinks,
        );
        _devices.add(current);
      }
    } catch (e) {
      appLogger.d('DLNA: could not read $location', error: e);
    } finally {
      _probing.remove(location);
    }
  }

  static Future<Set<String>> _sinkMimeTypes(Uri control) async {
    try {
      final body = await DlnaSoap.call(control, _connectionManager, 'GetProtocolInfo', const {});
      final sink = body['Sink'] ?? '';
      // Each entry is protocol:network:mime:info, e.g. http-get:*:video/mp4:*
      return {
        for (final entry in sink.split(','))
          if (entry.trim().startsWith('http-get:'))
            if (entry.trim().split(':') case [_, _, final mime, ...]) mime.toLowerCase(),
      };
    } catch (e) {
      appLogger.d('DLNA: GetProtocolInfo failed', error: e);
      return const {};
    }
  }
}

/// UPnP SOAP control calls.
class DlnaSoap {
  static Future<Map<String, String>> call(
    Uri control,
    String serviceType,
    String action,
    Map<String, String> arguments,
  ) async {
    final args = arguments.entries.map((e) => '<${e.key}>${_escape(e.value)}</${e.key}>').join();
    final envelope =
        '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body><u:$action xmlns:u="$serviceType">$args</u:$action></s:Body></s:Envelope>';
    final response = await http
        .post(
          control,
          headers: {'Content-Type': 'text/xml; charset="utf-8"', 'SOAPACTION': '"$serviceType#$action"'},
          body: utf8.encode(envelope),
        )
        .timeout(const Duration(seconds: 6));
    final text = utf8.decode(response.bodyBytes, allowMalformed: true);
    if (response.statusCode != 200) {
      final code = RegExp(r'<errorCode>(\d+)</errorCode>').firstMatch(text)?.group(1);
      throw DlnaException('$action failed (HTTP ${response.statusCode}${code == null ? '' : ', UPnP $code'})');
    }
    final doc = XmlDocument.parse(text);
    final result = doc.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == '${action}Response')
        .firstOrNull;
    return {for (final child in result?.childElements ?? const <XmlElement>[]) child.name.local: child.innerText};
  }

  static String _escape(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  static String escape(String value) => _escape(value);
}

class DlnaException implements Exception {
  const DlnaException(this.message);
  final String message;

  @override
  String toString() => 'DlnaException: $message';
}

/// AVTransport control of one renderer.
class DlnaPlayer {
  DlnaPlayer(this.renderer);

  final DlnaRenderer renderer;
  static const _service = 'urn:schemas-upnp-org:service:AVTransport:1';

  Future<Map<String, String>> _call(String action, [Map<String, String> args = const {}]) =>
      DlnaSoap.call(renderer.avTransportUrl, _service, action, {'InstanceID': '0', ...args});

  /// Hand the renderer [url] and start it. [seekable] says whether the
  /// server answers byte ranges (a file, not a live transcode).
  Future<void> load({
    required String url,
    required String mime,
    required String title,
    String? imageUrl,
    int? durationMs,
    required bool seekable,
  }) async {
    final flags = seekable ? 'DLNA.ORG_OP=01;DLNA.ORG_CI=0' : 'DLNA.ORG_OP=00;DLNA.ORG_CI=1';
    final duration = durationMs == null ? '' : ' duration="${formatTime(Duration(milliseconds: durationMs))}.000"';
    final metadata =
        '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
        '<item id="0" parentID="-1" restricted="1">'
        '<dc:title>${DlnaSoap.escape(title)}</dc:title>'
        '<upnp:class>object.item.videoItem</upnp:class>'
        '${imageUrl == null ? '' : '<upnp:albumArtURI>${DlnaSoap.escape(imageUrl)}</upnp:albumArtURI>'}'
        '<res protocolInfo="http-get:*:$mime:$flags"$duration>${DlnaSoap.escape(url)}</res>'
        '</item></DIDL-Lite>';
    // A renderer still holding the last title refuses a new URI on some
    // models; stopping first is harmless when it is idle.
    try {
      await _call('Stop');
    } catch (_) {}
    await _call('SetAVTransportURI', {'CurrentURI': url, 'CurrentURIMetaData': metadata});
    await play();
  }

  Future<void> play() => _call('Play', {'Speed': '1'});
  Future<void> pause() => _call('Pause');
  Future<void> stop() => _call('Stop');
  Future<void> seek(Duration position) => _call('Seek', {'Unit': 'REL_TIME', 'Target': formatTime(position)});

  /// PLAYING, PAUSED_PLAYBACK, STOPPED, TRANSITIONING or NO_MEDIA_PRESENT.
  Future<String> transportState() async => (await _call('GetTransportInfo'))['CurrentTransportState'] ?? 'STOPPED';

  Future<({Duration position, Duration duration})> position() async {
    final info = await _call('GetPositionInfo');
    return (position: parseTime(info['RelTime']), duration: parseTime(info['TrackDuration']));
  }

  static String formatTime(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.inHours}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
  }

  /// `H+:MM:SS[.F+]`; anything else (NOT_IMPLEMENTED) is zero.
  static Duration parseTime(String? value) {
    final match = RegExp(r'^(\d+):(\d{1,2}):(\d{1,2})(?:\.(\d+))?').firstMatch(value?.trim() ?? '');
    if (match == null) return Duration.zero;
    final fraction = match.group(4);
    return Duration(
      hours: int.parse(match.group(1)!),
      minutes: int.parse(match.group(2)!),
      seconds: int.parse(match.group(3)!),
      milliseconds: fraction == null ? 0 : int.parse(fraction.padRight(3, '0').substring(0, 3)),
    );
  }
}
