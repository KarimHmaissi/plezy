import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/services/ai/ai_key_store.dart';
import 'package:plezy/services/base_shared_preferences_service.dart';
import 'package:plezy/services/credential_vault.dart';
import 'package:plezy/services/sensitive_prefs.dart';
import 'package:plezy/services/tmdb/tmdb_key_store.dart';

import '../../test_helpers/prefs.dart';

/// Fake credentials shaped like TMDB's (never real keys).
const fakeApiKey = '0123456789abcdef0123456789abcdef';
const fakeToken = 'eyJhbGciOiJIUzI1NiJ9.eyJmYWtlIjoidGVzdC1vbmx5In0.ZmFrZS1zaWduYXR1cmUtZm9yLXRlc3Rz';

void main() {
  setUp(() {
    resetSharedPreferencesForTest();
    CredentialVault.resetKeyForTesting();
  });

  group('storage', () {
    test('round-trips the key, encrypted at rest', () async {
      expect(await TmdbKeyStore.read(), isNull);
      expect(await TmdbKeyStore.hasKey(), isFalse);

      await TmdbKeyStore.write('  $fakeApiKey ');

      final prefs = await BaseSharedPreferencesService.sharedCache();
      final raw = prefs.getString(tmdbApiKeyPref)!;
      expect(raw, isNot(contains(fakeApiKey)));
      expect(CredentialVault.isProtected(raw), isTrue);
      expect(await TmdbKeyStore.read(), fakeApiKey);
      expect(await TmdbKeyStore.hasKey(), isTrue);

      await TmdbKeyStore.remove();
      expect(prefs.containsKey(tmdbApiKeyPref), isFalse);
      expect(await TmdbKeyStore.read(), isNull);
    });

    test('is its own slot, separate from the Anthropic key', () async {
      await TmdbKeyStore.write(fakeToken);
      expect(await AiKeyStore.read(), isNull);
      expect(TmdbKeyStore.prefKey, isNot(AiKeyStore.prefKey));
    });

    test('shows only the last four characters', () {
      expect(TmdbKeyStore.hint(fakeApiKey), '••••cdef');
      expect(TmdbKeyStore.hint('abc'), '••••');
    });

    test('is registered as a credential', () {
      expect(isSensitivePrefKey(TmdbKeyStore.prefKey), isTrue);
    });
  });

  group('key kinds', () {
    test('a 32-hex value is the v3 API key, a JWT is the Read Access Token', () {
      expect(TmdbKeyStore.kindOf(fakeApiKey), TmdbKeyKind.apiKey);
      expect(TmdbKeyStore.kindOf(fakeApiKey.toUpperCase()), TmdbKeyKind.apiKey);
      expect(TmdbKeyStore.kindOf(' $fakeToken '), TmdbKeyKind.readAccessToken);
      expect(TmdbKeyStore.kindOf('sk-ant-123'), isNull);
      expect(TmdbKeyStore.kindOf('${fakeApiKey}0'), isNull);
      expect(TmdbKeyStore.kindOf('not.a jwt.value'), isNull);
      expect(TmdbKeyStore.kindOf(''), isNull);
    });
  });

  group('validate request', () {
    test('the API key goes as the api_key query parameter, with no Authorization header', () {
      final request = TmdbKeyStore.validateRequest(fakeApiKey);
      expect(request.method, 'GET');
      expect(request.url.replace(query: '').toString(), 'https://api.themoviedb.org/3/authentication?');
      expect(request.url.queryParameters, {'api_key': fakeApiKey});
      expect(request.headers.containsKey('Authorization'), isFalse);
    });

    test('the Read Access Token goes as a Bearer header, never in the URL', () {
      final request = TmdbKeyStore.validateRequest(fakeToken);
      expect(request.method, 'GET');
      expect(request.url.toString(), 'https://api.themoviedb.org/3/authentication');
      expect(request.headers['Authorization'], 'Bearer $fakeToken');
    });
  });

  group('check', () {
    late List<http.BaseRequest> sent;

    MockClient reply(int status, Object body) => MockClient((request) async {
      sent.add(request);
      return http.Response(jsonEncode(body), status);
    });

    setUp(() => sent = []);

    test('200 with success true is ok, for both key kinds', () async {
      final client = reply(200, {'success': true, 'status_code': 1, 'status_message': 'Success.'});
      expect(await TmdbKeyStore.check(fakeApiKey, client: client), AiKeyCheck.ok);
      expect(await TmdbKeyStore.check(fakeToken, client: client), AiKeyCheck.ok);
      expect(sent.first.url.queryParameters['api_key'], fakeApiKey);
      expect(sent.last.headers['Authorization'], 'Bearer $fakeToken');
    });

    test('401 is invalid', () async {
      final client = reply(401, {
        'status_code': 7,
        'status_message': 'Invalid API key: You must be granted a valid key.',
        'success': false,
      });
      expect(await TmdbKeyStore.check(fakeApiKey, client: client), AiKeyCheck.invalid);
    });

    test('200 without success true is invalid', () async {
      expect(await TmdbKeyStore.check(fakeApiKey, client: reply(200, {'success': false})), AiKeyCheck.invalid);
    });

    test('a server error or network failure is unreachable', () async {
      expect(await TmdbKeyStore.check(fakeApiKey, client: reply(503, {})), AiKeyCheck.unreachable);
      final failing = MockClient((_) async => throw const SocketException('offline'));
      expect(await TmdbKeyStore.check(fakeToken, client: failing), AiKeyCheck.unreachable);
    });

    test('a value that is neither kind is invalid without a request', () async {
      expect(await TmdbKeyStore.check('sk-ant-nope', client: reply(200, {'success': true})), AiKeyCheck.invalid);
      expect(sent, isEmpty);
    });
  });
}
