import 'package:http/http.dart' as http;

import '../base_shared_preferences_service.dart';
import '../credential_vault.dart';
import '../sensitive_prefs.dart';

enum AiKeyCheck { ok, invalid, unreachable }

/// The Anthropic API key for the AI helper: stored on this device only,
/// encrypted with [CredentialVault], never logged, exported or backed up
/// (it isn't a portable setting, and it's registered as a credential in
/// `sensitive_prefs.dart`).
abstract final class AiKeyStore {
  static const String prefKey = aiApiKeyPref;

  static Future<String?> read() async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    final stored = prefs.getString(prefKey);
    if (stored == null || stored.isEmpty) return null;
    return CredentialVault.reveal(stored);
  }

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

  /// Check [key] with a free request (listing models; no tokens are used).
  static Future<AiKeyCheck> check(String key, {http.Client? client}) async {
    final c = client ?? http.Client();
    try {
      final response = await c
          .get(
            Uri.parse('https://api.anthropic.com/v1/models?limit=1'),
            headers: {'x-api-key': key.trim(), 'anthropic-version': '2023-06-01'},
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) return AiKeyCheck.ok;
      if (response.statusCode == 401 || response.statusCode == 403) return AiKeyCheck.invalid;
      return AiKeyCheck.unreachable;
    } catch (_) {
      return AiKeyCheck.unreachable;
    } finally {
      if (client == null) c.close();
    }
  }
}
