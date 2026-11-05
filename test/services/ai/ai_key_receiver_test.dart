import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/services/ai/ai_key_receiver.dart';
import 'package:plezy/services/ai/ai_key_store.dart';
import 'package:plezy/services/credential_vault.dart';
import 'package:plezy/services/tmdb/tmdb_key_store.dart';

import '../../test_helpers/prefs.dart';

void main() {
  late List<String> saved;
  late AiKeyCheck nextCheck;

  setUp(() {
    saved = [];
    nextCheck = AiKeyCheck.ok;
  });

  Future<AiKeyReceiver> start({KeyReceiverKind kind = KeyReceiverKind.anthropic}) async => (await AiKeyReceiver.start(
    kind: kind,
    bindTo: InternetAddress.loopbackIPv4,
    checkKey: (_) async => nextCheck,
    saveKey: (key) async => saved.add(key),
  ))!;

  Future<http.Response> post(AiKeyReceiver r, String code, String key) =>
      http.post(Uri.parse(r.address), body: {'code': code, 'key': key});

  test('serves the form, saves a working key with the right code, then closes', () async {
    final r = await start();
    expect((await http.get(Uri.parse(r.address))).body, contains('name="code"'));

    final response = await post(r, r.code, ' sk-ant-test-1234 ');
    expect(response.body, contains('Key saved'));
    expect(await r.result, AiKeyReceiveResult.saved);
    expect(saved, ['sk-ant-test-1234']);

    await Future<void>.delayed(const Duration(milliseconds: 400));
    await expectLater(http.get(Uri.parse(r.address)), throwsA(anything), reason: 'server is closed after one use');
  });

  test('three wrong codes close the page without saving', () async {
    final r = await start();
    final wrong = r.code == '111111' ? '222222' : '111111';
    expect((await post(r, wrong, 'sk-ant-x')).body, contains('2 tries left'));
    await post(r, wrong, 'sk-ant-x');
    expect((await post(r, wrong, 'sk-ant-x')).body, contains('Too many wrong codes'));
    expect(await r.result, AiKeyReceiveResult.tooManyAttempts);
    expect(saved, isEmpty);
  });

  test('a rejected key is not saved; a malformed one asks again', () async {
    final r = await start();
    expect((await post(r, r.code, 'not-a-key')).body, contains('start with sk-ant-'));
    nextCheck = AiKeyCheck.invalid;
    expect((await post(r, r.code, 'sk-ant-bad')).body, contains('rejected'));
    expect(await r.result, AiKeyReceiveResult.rejected);
    expect(saved, isEmpty);
  });

  group('TMDB key', () {
    const fakeApiKey = '0123456789abcdef0123456789abcdef';

    test('the page asks for a TMDB key, not an Anthropic one', () async {
      final r = await start(kind: KeyReceiverKind.tmdb);
      final page = (await http.get(Uri.parse(r.address))).body;
      expect(page, contains('Plezy · TMDB key'));
      expect(page, contains('TMDB API key or Read Access Token'));
      expect(page, isNot(contains('Anthropic')));
      expect(page, isNot(contains('sk-ant-')));
      r.cancel();
    });

    test('checks and saves with the TMDB checker and saver', () async {
      final checked = <String>[];
      final r = (await AiKeyReceiver.start(
        kind: KeyReceiverKind.tmdb,
        bindTo: InternetAddress.loopbackIPv4,
        checkKey: (key) async {
          checked.add(key);
          return AiKeyCheck.ok;
        },
        saveKey: (key) async => saved.add(key),
      ))!;
      expect((await post(r, r.code, 'sk-ant-wrong-service')).body, contains('look like a TMDB key'));
      expect(checked, isEmpty);
      expect((await post(r, r.code, ' $fakeApiKey ')).body, contains('Key saved'));
      expect(await r.result, AiKeyReceiveResult.saved);
      expect(checked, [fakeApiKey]);
      expect(saved, [fakeApiKey]);
    });

    test('a rejected key names TMDB and is not saved', () async {
      nextCheck = AiKeyCheck.invalid;
      final r = await start(kind: KeyReceiverKind.tmdb);
      final body = (await post(r, r.code, fakeApiKey)).body;
      expect(body, contains('TMDB rejected that key'));
      expect(await r.result, AiKeyReceiveResult.rejected);
      expect(saved, isEmpty);
    });

    test('an unreachable TMDB still saves, and says so', () async {
      nextCheck = AiKeyCheck.unreachable;
      final r = await start(kind: KeyReceiverKind.tmdb);
      expect((await post(r, r.code, fakeApiKey)).body, contains('couldn&#39;t reach TMDB'));
      expect(await r.result, AiKeyReceiveResult.savedUnchecked);
      expect(saved, [fakeApiKey]);
    });

    test('by default the TMDB kind checks with TmdbKeyStore and saves into it, encrypted', () async {
      // The prefs fixture starts the test binding, which fakes every
      // HttpClient (status 400); this test talks to a real loopback server.
      final overrides = HttpOverrides.current;
      resetSharedPreferencesForTest();
      HttpOverrides.global = overrides;
      CredentialVault.resetKeyForTesting();
      expect(KeyReceiverKind.tmdb.check == TmdbKeyStore.check, isTrue);
      expect(KeyReceiverKind.anthropic.check == AiKeyStore.check, isTrue);
      // Only the network check is replaced; the real saver runs.
      final r = (await AiKeyReceiver.start(
        kind: KeyReceiverKind.tmdb,
        bindTo: InternetAddress.loopbackIPv4,
        checkKey: (_) async => AiKeyCheck.ok,
      ))!;
      await post(r, r.code, fakeApiKey);
      expect(await r.result, AiKeyReceiveResult.saved);
      expect(await TmdbKeyStore.read(), fakeApiKey);
      expect(await AiKeyStore.read(), isNull);
    });
  });

  test('the Anthropic page keeps its wording', () async {
    final r = await start();
    final page = (await http.get(Uri.parse(r.address))).body;
    expect(page, contains('Anthropic API key'));
    expect(page, isNot(contains('TMDB')));
    r.cancel();
  });

  test('only private and loopback addresses count as local', () {
    expect(AiKeyReceiver.isPrivate(InternetAddress('192.168.1.20')), isTrue);
    expect(AiKeyReceiver.isPrivate(InternetAddress('10.0.0.5')), isTrue);
    expect(AiKeyReceiver.isPrivate(InternetAddress('172.20.1.1')), isTrue);
    expect(AiKeyReceiver.isPrivate(InternetAddress('172.32.1.1')), isFalse);
    expect(AiKeyReceiver.isPrivate(InternetAddress('8.8.8.8')), isFalse);
  });

  test('picks the Wi-Fi address over a private mobile data address', () {
    InternetAddress a(String ip) => InternetAddress(ip);
    expect(
      AiKeyReceiver.pickLanAddress([
        (name: 'rmnet_data1', address: a('10.84.2.7')),
        (name: 'wlan0', address: a('192.168.1.23')),
      ])?.address,
      '192.168.1.23',
    );
    expect(AiKeyReceiver.pickLanAddress([(name: 'rmnet_data1', address: a('10.84.2.7'))]), isNull);
    expect(AiKeyReceiver.pickLanAddress([(name: 'bridge0', address: a('172.20.0.1'))])?.address, '172.20.0.1');
    expect(AiKeyReceiver.pickLanAddress([(name: 'wlan0', address: a('100.70.1.2'))]), isNull);
  });
}
