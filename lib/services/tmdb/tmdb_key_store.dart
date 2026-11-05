import 'dart:convert';

import 'package:http/http.dart' as http;

import '../ai/ai_key_store.dart' show AiKeyCheck;
import '../base_shared_preferences_service.dart';
import '../credential_vault.dart';
import '../sensitive_prefs.dart';

/// Which of TMDB's two credentials a value is.
enum TmdbKeyKind {
  /// The 32-character v3 "API Key", sent as the `api_key` query parameter.
  apiKey,

  /// The long v4 "API Read Access Token" (a JWT), sent as `Authorization: Bearer`.
  readAccessToken,
}

/// The TMDB credential for The Reel and other TMDB features: stored on this
/// device only, encrypted with [CredentialVault], never logged, exported or
/// backed up (it isn't a portable setting, and it's registered as a
/// credential in `sensitive_prefs.dart`, like the Anthropic key).
///
/// Either TMDB credential works: TMDB's v3 API takes "either a single query
/// parameter, `api_key`, or ... your access token as a `Bearer` token"
/// (https://developer.themoviedb.org/docs/authentication-application).
abstract final class TmdbKeyStore {
  static const String prefKey = tmdbApiKeyPref;

  static final RegExp _apiKey = RegExp(r'^[0-9a-fA-F]{32}$');
  static final RegExp _jwt = RegExp(r'^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$');

  static Future<String?> read() async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    final stored = prefs.getString(prefKey);
    if (stored == null || stored.isEmpty) return null;
    return CredentialVault.reveal(stored);
  }

  static Future<bool> hasKey() async => (await read() ?? '').isNotEmpty;

  static Future<void> write(String key) async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    await prefs.setString(prefKey, await CredentialVault.protect(key.trim()));
  }

  static Future<void> remove() async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    await prefs.remove(prefKey);
  }

  /// The last four characters, for showing which key is set.
  static String hint(String key) => key.length <= 4 ? '••••' : '••••${key.substring(key.length - 4)}';

  /// Which credential [key] is, or null when it looks like neither.
  static TmdbKeyKind? kindOf(String key) {
    final k = key.trim();
    if (_apiKey.hasMatch(k)) return TmdbKeyKind.apiKey;
    if (k.startsWith('eyJ') && _jwt.hasMatch(k)) return TmdbKeyKind.readAccessToken;
    return null;
  }

  static bool looksValid(String key) => kindOf(key) != null;

  /// The validate-key request for [key]: `GET /3/authentication`, with the
  /// API key as `api_key` or the Read Access Token as a Bearer header.
  static http.Request validateRequest(String key) {
    final k = key.trim();
    final kind = kindOf(k);
    final base = Uri.parse('https://api.themoviedb.org/3/authentication');
    final request = http.Request(
      'GET',
      kind == TmdbKeyKind.apiKey ? base.replace(queryParameters: {'api_key': k}) : base,
    );
    request.headers['Accept'] = 'application/json';
    if (kind == TmdbKeyKind.readAccessToken) request.headers['Authorization'] = 'Bearer $k';
    return request;
  }

  /// Check [key] against TMDB's validate-key endpoint. Never logs the key or
  /// the request (the URL carries an API key).
  static Future<AiKeyCheck> check(String key, {http.Client? client}) async {
    if (!looksValid(key)) return AiKeyCheck.invalid;
    final c = client ?? http.Client();
    try {
      final response = await http.Response.fromStream(
        await c.send(validateRequest(key)).timeout(const Duration(seconds: 15)),
      ).timeout(const Duration(seconds: 15));
      if (response.statusCode == 401 || response.statusCode == 403) return AiKeyCheck.invalid;
      if (response.statusCode != 200) return AiKeyCheck.unreachable;
      final body = jsonDecode(response.body);
      return body is Map && body['success'] == true ? AiKeyCheck.ok : AiKeyCheck.invalid;
    } catch (_) {
      return AiKeyCheck.unreachable;
    } finally {
      if (client == null) c.close();
    }
  }
}
