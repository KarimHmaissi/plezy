import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../utils/app_logger.dart';
import '../tmdb/tmdb_key_store.dart';
import 'ai_key_store.dart';

/// How a key hand-over ended.
enum AiKeyReceiveResult { saved, savedUnchecked, rejected, tooManyAttempts, timedOut, cancelled }

/// Which key the page asks for: its wording, format check, and how the key
/// is checked and saved.
class KeyReceiverKind {
  const KeyReceiverKind({
    required this.service,
    required this.pageTitle,
    required this.fieldLabel,
    required this.placeholder,
    required this.formatError,
    required this.looksValid,
    required this.check,
    required this.save,
  });

  /// Who checks the key, for "Anthropic rejected that key".
  final String service;
  final String pageTitle;
  final String fieldLabel;
  final String placeholder;
  final String formatError;
  final bool Function(String key) looksValid;
  final Future<AiKeyCheck> Function(String key) check;
  final Future<void> Function(String key) save;

  static const KeyReceiverKind anthropic = KeyReceiverKind(
    service: 'Anthropic',
    pageTitle: 'AI key',
    fieldLabel: 'Anthropic API key',
    placeholder: 'sk-ant-…',
    formatError: 'That doesn\'t look like an Anthropic key (they start with sk-ant-).',
    looksValid: _looksLikeAnthropicKey,
    check: AiKeyStore.check,
    save: AiKeyStore.write,
  );

  static const KeyReceiverKind tmdb = KeyReceiverKind(
    service: 'TMDB',
    pageTitle: 'TMDB key',
    fieldLabel: 'TMDB API key or Read Access Token',
    placeholder: '32-character API key or eyJ… token',
    formatError:
        'That doesn\'t look like a TMDB key. Use the 32-character API key or the long API Read Access Token '
        'from themoviedb.org ▸ Settings ▸ API.',
    looksValid: TmdbKeyStore.looksValid,
    check: TmdbKeyStore.check,
    save: TmdbKeyStore.write,
  );

  static bool _looksLikeAnthropicKey(String key) => key.startsWith('sk-ant-');
}

/// A one-time page on the local network for typing or pasting the API key
/// on another device (a phone or laptop browser) instead of on the TV.
///
/// Listens only on this device's private LAN address, accepts connections
/// only from private addresses, requires a random 6-digit [code], and shuts
/// down after one successful hand-over, [maxAttempts] wrong codes, or
/// [lifetime]. The key is never logged.
class AiKeyReceiver {
  AiKeyReceiver._(this._server, this.code, this.address, this.kind, this._checkKey, this._saveKey);

  static const int maxAttempts = 3;
  static const Duration lifetime = Duration(minutes: 5);

  final HttpServer _server;

  /// Which key this page receives.
  final KeyReceiverKind kind;
  final Future<AiKeyCheck> Function(String key) _checkKey;
  final Future<void> Function(String key) _saveKey;

  /// The code to enter on the page.
  final String code;

  /// `http://<LAN IP>:<port>` to open in the other device's browser.
  final String address;

  final Completer<AiKeyReceiveResult> _done = Completer();
  Future<AiKeyReceiveResult> get result => _done.future;
  int _wrongCodes = 0;
  Timer? _timer;

  /// Start listening, or null when this device has no private LAN address.
  static Future<AiKeyReceiver?> start({
    KeyReceiverKind kind = KeyReceiverKind.anthropic,
    @visibleForTesting InternetAddress? bindTo,
    @visibleForTesting Future<AiKeyCheck> Function(String key)? checkKey,
    @visibleForTesting Future<void> Function(String key)? saveKey,
  }) async {
    final ip = bindTo ?? await privateLanAddress();
    if (ip == null) return null;
    final server = await HttpServer.bind(ip, 0);
    final code = (Random.secure().nextInt(900000) + 100000).toString();
    final receiver = AiKeyReceiver._(
      server,
      code,
      'http://${ip.address}:${server.port}',
      kind,
      checkKey ?? kind.check,
      saveKey ?? kind.save,
    );
    receiver._listen();
    return receiver;
  }

  /// This device's private IPv4 address (10/8, 172.16/12, 192.168/16) on
  /// the home network: Wi-Fi or Ethernet first. A phone's mobile data link
  /// can have a private address too, which nothing at home could reach.
  static Future<InternetAddress?> privateLanAddress() async {
    final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
    return pickLanAddress([
      for (final interface in interfaces)
        for (final address in interface.addresses) (name: interface.name, address: address),
    ]);
  }

  @visibleForTesting
  static InternetAddress? pickLanAddress(List<({String name, InternetAddress address})> candidates) {
    final usable = [
      for (final c in candidates)
        if (isPrivate(c.address) && !_mobileOrTunnel.hasMatch(c.name)) c,
    ];
    final lan = usable.where((c) => _lan.hasMatch(c.name)).firstOrNull;
    return (lan ?? usable.firstOrNull)?.address;
  }

  /// Wi-Fi and Ethernet interface names (Android, Linux, macOS, Windows).
  static final RegExp _lan = RegExp(r'^(wlan|wlp|wl|en|eth|Wi-?Fi|Ethernet)', caseSensitive: false);

  /// Mobile data and VPN interfaces: never the home network.
  static final RegExp _mobileOrTunnel = RegExp(r'^(rmnet|ccmni|pdp|v4-|clat|tun|ppp|ipsec|utun|dummy)');

  static bool isPrivate(InternetAddress address) {
    if (address.type != InternetAddressType.IPv4) return false;
    final b = address.rawAddress;
    return b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) || (b[0] == 192 && b[1] == 168);
  }

  void _listen() {
    _timer = Timer(lifetime, () => _finish(AiKeyReceiveResult.timedOut));
    _server.listen((request) => unawaited(_handle(request)), onError: (Object _) {});
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      final remote = request.connectionInfo?.remoteAddress;
      if (remote == null || !(isPrivate(remote) || remote.isLoopback)) {
        response.statusCode = HttpStatus.forbidden;
        return;
      }
      if (request.method == 'GET' && request.uri.path == '/') {
        _page(response, _formHtml());
        return;
      }
      if (request.method != 'POST' || request.uri.path != '/') {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      final body = await utf8.decoder.bind(request).join();
      final fields = Uri.splitQueryString(body);
      if ((fields['code'] ?? '').trim() != code) {
        _wrongCodes++;
        if (_wrongCodes >= maxAttempts) {
          _page(response, _messageHtml('Too many wrong codes. Start again from Plezy.'));
          _finish(AiKeyReceiveResult.tooManyAttempts);
        } else {
          _page(response, _formHtml(error: 'Wrong code. ${maxAttempts - _wrongCodes} tries left.'));
        }
        return;
      }
      final key = (fields['key'] ?? '').trim();
      if (!kind.looksValid(key)) {
        _page(response, _formHtml(error: kind.formatError));
        return;
      }
      final check = await _checkKey(key);
      if (check == AiKeyCheck.invalid) {
        _page(response, _messageHtml('${kind.service} rejected that key. Nothing was saved. Start again from Plezy.'));
        _finish(AiKeyReceiveResult.rejected);
        return;
      }
      await _saveKey(key);
      _page(
        response,
        _messageHtml(
          check == AiKeyCheck.ok
              ? 'Key saved on the TV and working. You can close this page.'
              : 'Key saved on the TV. Plezy couldn\'t reach ${kind.service} to check it; it will be checked on first use.',
        ),
      );
      _finish(check == AiKeyCheck.ok ? AiKeyReceiveResult.saved : AiKeyReceiveResult.savedUnchecked);
    } catch (e) {
      // Never include the request in the log.
      appLogger.w('Key receiver (${kind.service}): request failed (${e.runtimeType})');
      response.statusCode = HttpStatus.internalServerError;
    } finally {
      await response.close();
    }
  }

  void _page(HttpResponse response, String html) {
    response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.html
      ..headers.set('Cache-Control', 'no-store')
      ..write(html);
  }

  String _shell(String content) =>
      '<!doctype html><html><head><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width,initial-scale=1">'
      '<title>Plezy · ${kind.pageTitle}</title><style>'
      'body{font-family:system-ui,sans-serif;background:#111;color:#eee;max-width:520px;margin:40px auto;padding:0 16px}'
      'input{width:100%;box-sizing:border-box;font-size:18px;padding:10px;margin:6px 0 16px;border-radius:8px;border:1px solid #555;background:#222;color:#eee}'
      'button{font-size:18px;padding:10px 20px;border-radius:8px;border:0;background:#e5a00d;color:#111}'
      '.err{color:#ff8a80}</style></head><body><h2>Plezy · ${kind.pageTitle}</h2>$content</body></html>';

  String _formHtml({String? error}) => _shell(
    '${error == null ? '' : '<p class="err">${const HtmlEscape().convert(error)}</p>'}'
    '<form method="post" autocomplete="off">'
    '<label>Code shown on the TV<input name="code" inputmode="numeric" maxlength="6" required></label>'
    '<label>${_escape(kind.fieldLabel)}<input name="key" type="password" required '
    'placeholder="${_escapeAttribute(kind.placeholder)}"></label>'
    '<button type="submit">Send to Plezy</button></form>'
    '<p>The key goes straight to the TV over your home network and is stored encrypted there.</p>',
  );

  String _messageHtml(String message) => _shell('<p>${_escape(message)}</p>');

  static String _escape(String text) => const HtmlEscape().convert(text);
  static String _escapeAttribute(String text) => const HtmlEscape(HtmlEscapeMode.attribute).convert(text);

  void cancel() => _finish(AiKeyReceiveResult.cancelled);

  void _finish(AiKeyReceiveResult result) {
    if (_done.isCompleted) return;
    _timer?.cancel();
    _done.complete(result);
    // Let the last response go out, then stop listening.
    Future<void>.delayed(const Duration(milliseconds: 300), () => _server.close(force: true));
  }
}
