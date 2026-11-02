import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../../utils/app_logger.dart';

/// Claude models the helper uses, with their prices (US dollars per million
/// tokens) for spend tracking.
enum ClaudeModel {
  sonnet('claude-sonnet-5-5', input: 2.00, output: 10.00, cacheRead: 0.20, cacheWrite: 2.50),
  haiku('claude-haiku-5-5', input: 0.10, output: 0.50, cacheRead: 0.01, cacheWrite: 0.125);

  const ClaudeModel(
    this.id, {
    required this.input,
    required this.output,
    required this.cacheRead,
    required this.cacheWrite,
  });

  final String id;
  final double input;
  final double output;
  final double cacheRead;
  final double cacheWrite;

  /// Dollars for one response's `usage`.
  double cost(Map<String, dynamic> usage) {
    int n(String key) => (usage[key] as num?)?.toInt() ?? 0;
    return (n('input_tokens') * input +
            n('output_tokens') * output +
            n('cache_read_input_tokens') * cacheRead +
            n('cache_creation_input_tokens') * cacheWrite) /
        1e6;
  }
}

class ClaudeApiException implements Exception {
  ClaudeApiException(this.statusCode, this.type, this.message);
  final int statusCode;
  final String? type;
  final String message;

  bool get isAuth => statusCode == 401 || statusCode == 403;

  @override
  String toString() => 'Claude API $statusCode ${type ?? ''}: $message';
}

/// The Messages API over HTTPS (there's no official Anthropic SDK for
/// Dart). Retries rate limits, overload and server errors with backoff,
/// honouring `retry-after`. Never logs the key or message content.
class ClaudeClient {
  ClaudeClient(this._apiKey, {http.Client? httpClient, this.maxRetries = 3})
    : _http = httpClient ?? http.Client(),
      _ownsHttp = httpClient == null;

  static const String apiVersion = '2026-10-21';
  static final Uri _messages = Uri.parse('https://api.anthropic.com/v1/messages');

  final String _apiKey;
  final http.Client _http;
  final bool _ownsHttp;
  final int maxRetries;

  /// POST /v1/messages with [body]; returns the decoded response.
  Future<Map<String, dynamic>> createMessage(Map<String, Object?> body, {List<String> betas = const []}) async {
    final payload = jsonEncode(body);
    for (var attempt = 0; ; attempt++) {
      http.Response response;
      try {
        response = await _http
            .post(
              _messages,
              headers: {
                'content-type': 'application/json',
                'x-api-key': _apiKey,
                'anthropic-version': apiVersion,
                if (betas.isNotEmpty) 'anthropic-beta': betas.join(','),
              },
              body: payload,
            )
            .timeout(const Duration(minutes: 3));
      } on TimeoutException {
        if (attempt >= maxRetries) rethrow;
        await _backoff(attempt, null);
        continue;
      } on http.ClientException {
        if (attempt >= maxRetries) rethrow;
        await _backoff(attempt, null);
        continue;
      }
      if (response.statusCode == 200) {
        return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      }
      final retryable = response.statusCode == 429 || response.statusCode == 529 || response.statusCode >= 500;
      if (retryable && attempt < maxRetries) {
        appLogger.d('Claude: HTTP ${response.statusCode}, retrying');
        await _backoff(attempt, response.headers['retry-after']);
        continue;
      }
      String? type;
      var message = 'HTTP ${response.statusCode}';
      try {
        final error = (jsonDecode(utf8.decode(response.bodyBytes)) as Map)['error'] as Map?;
        type = error?['type'] as String?;
        message = error?['message'] as String? ?? message;
      } catch (_) {}
      throw ClaudeApiException(response.statusCode, type, message);
    }
  }

  /// Fork: [createMessage] streamed (server-sent events). [onEvent] gets
  /// each event as it arrives (`content_block_start`, `content_block_delta`
  /// with `text_delta` / `input_json_delta`, …); the result is the whole
  /// message, assembled the same as [createMessage] returns it (thinking
  /// blocks with their signatures, tool inputs parsed). Retries like
  /// [createMessage] until the first byte arrives, never after.
  Future<Map<String, dynamic>> streamMessage(
    Map<String, Object?> body, {
    List<String> betas = const [],
    void Function(Map<String, dynamic> event)? onEvent,
  }) async {
    final payload = jsonEncode({...body, 'stream': true});
    for (var attempt = 0; ; attempt++) {
      final request = http.Request('POST', _messages)
        ..headers.addAll({
          'content-type': 'application/json',
          'accept': 'text/event-stream',
          'x-api-key': _apiKey,
          'anthropic-version': apiVersion,
          if (betas.isNotEmpty) 'anthropic-beta': betas.join(','),
        })
        ..body = payload;
      http.StreamedResponse response;
      try {
        response = await _http.send(request).timeout(const Duration(minutes: 1));
      } on TimeoutException {
        if (attempt >= maxRetries) rethrow;
        await _backoff(attempt, null);
        continue;
      } on http.ClientException {
        if (attempt >= maxRetries) rethrow;
        await _backoff(attempt, null);
        continue;
      }
      if (response.statusCode != 200) {
        final text = await response.stream.bytesToString();
        final retryable = response.statusCode == 429 || response.statusCode == 529 || response.statusCode >= 500;
        if (retryable && attempt < maxRetries) {
          appLogger.d('Claude: HTTP ${response.statusCode}, retrying');
          await _backoff(attempt, response.headers['retry-after']);
          continue;
        }
        String? type;
        var message = 'HTTP ${response.statusCode}';
        try {
          final error = (jsonDecode(text) as Map)['error'] as Map?;
          type = error?['type'] as String?;
          message = error?['message'] as String? ?? message;
        } catch (_) {}
        throw ClaudeApiException(response.statusCode, type, message);
      }
      // A reply that isn't a stream (a proxy, a test) is the whole message.
      final type = response.headers['content-type'] ?? '';
      if (!type.contains('event-stream') && (type.contains('json') || type.isEmpty)) {
        return jsonDecode(await response.stream.bytesToString()) as Map<String, dynamic>;
      }
      final message = StreamedMessage();
      await for (final event in sseEvents(response.stream).timeout(const Duration(minutes: 3))) {
        message.add(event);
        onEvent?.call(event);
      }
      if (message.error case final e?) {
        throw ClaudeApiException(500, e['type'] as String?, e['message'] as String? ?? 'stream error');
      }
      return message.toJson();
    }
  }

  Future<void> _backoff(int attempt, String? retryAfter) {
    final seconds = int.tryParse(retryAfter ?? '');
    final delay = seconds != null
        ? Duration(seconds: seconds.clamp(1, 60))
        : Duration(milliseconds: (1000 * pow(2, attempt)).toInt() + Random().nextInt(400));
    return Future<void>.delayed(delay);
  }

  void close() {
    if (_ownsHttp) _http.close();
  }
}

/// Fork: server-sent events from [bytes], each `data:` payload decoded.
Stream<Map<String, dynamic>> sseEvents(Stream<List<int>> bytes) async* {
  final data = StringBuffer();
  await for (final line in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.isEmpty) {
      if (data.isNotEmpty) {
        final decoded = jsonDecode(data.toString());
        data.clear();
        if (decoded is Map<String, dynamic>) yield decoded;
      }
    } else if (line.startsWith('data:')) {
      data.write(line.substring(5).trimLeft());
    }
  }
  if (data.isNotEmpty) {
    final decoded = jsonDecode(data.toString());
    if (decoded is Map<String, dynamic>) yield decoded;
  }
}

/// Fork: a streamed message put back together from its events.
class StreamedMessage {
  final List<Map<String, dynamic>> _blocks = [];
  final Map<int, StringBuffer> _json = {};
  final Map<String, dynamic> _usage = {};
  String? stopReason;
  Map<String, dynamic>? error;

  /// Text of the tool input being written for block [index] so far.
  String partialInput(int index) => _json[index]?.toString() ?? '';

  void add(Map<String, dynamic> e) {
    switch (e['type']) {
      case 'message_start':
        _usage.addAll(((e['message'] as Map?)?['usage'] as Map?)?.cast<String, dynamic>() ?? const {});
      case 'content_block_start':
        final i = e['index'] as int;
        while (_blocks.length <= i) {
          _blocks.add(<String, dynamic>{});
        }
        _blocks[i] = Map<String, dynamic>.of((e['content_block'] as Map).cast<String, dynamic>());
      case 'content_block_delta':
        final i = e['index'] as int;
        final delta = (e['delta'] as Map).cast<String, dynamic>();
        final block = _blocks[i];
        switch (delta['type']) {
          case 'text_delta':
            block['text'] = '${block['text'] ?? ''}${delta['text']}';
          case 'input_json_delta':
            (_json[i] ??= StringBuffer()).write(delta['partial_json']);
          case 'thinking_delta':
            block['thinking'] = '${block['thinking'] ?? ''}${delta['thinking']}';
          case 'signature_delta':
            block['signature'] = '${block['signature'] ?? ''}${delta['signature']}';
        }
      case 'content_block_stop':
        final i = e['index'] as int;
        final json = _json[i]?.toString();
        if (json != null) _blocks[i]['input'] = json.trim().isEmpty ? <String, dynamic>{} : jsonDecode(json);
      case 'message_delta':
        stopReason = ((e['delta'] as Map?)?['stop_reason'] as String?) ?? stopReason;
        _usage.addAll((e['usage'] as Map?)?.cast<String, dynamic>() ?? const {});
      case 'error':
        error = (e['error'] as Map?)?.cast<String, dynamic>();
    }
  }

  Map<String, dynamic> toJson() => {'content': _blocks, 'stop_reason': stopReason, 'usage': _usage};
}

/// Fork: the value of string field [key] in a JSON object that is still
/// being written ([json] may stop mid-string): what's there so far, or null
/// before the field starts. For showing a tool's text as the model types it.
String? partialJsonString(String json, String key) {
  final start = RegExp('"${RegExp.escape(key)}"\\s*:\\s*"').firstMatch(json);
  if (start == null) return null;
  final out = StringBuffer();
  var i = start.end;
  while (i < json.length) {
    final c = json[i];
    if (c == '"') break;
    if (c == '\\') {
      if (i + 1 >= json.length) break;
      final n = json[i + 1];
      switch (n) {
        case 'n':
          out.write('\n');
        case 't':
          out.write('\t');
        case 'u':
          if (i + 5 >= json.length) return out.toString();
          out.writeCharCode(int.tryParse(json.substring(i + 2, i + 6), radix: 16) ?? 0x3f);
          i += 4;
        default:
          out.write(n);
      }
      i += 2;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}
