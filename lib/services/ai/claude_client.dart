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
