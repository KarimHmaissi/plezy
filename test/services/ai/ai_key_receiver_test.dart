import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/services/ai/ai_key_receiver.dart';
import 'package:plezy/services/ai/ai_key_store.dart';

void main() {
  late List<String> saved;
  late AiKeyCheck nextCheck;

  setUp(() {
    saved = [];
    nextCheck = AiKeyCheck.ok;
  });

  Future<AiKeyReceiver> start() async => (await AiKeyReceiver.start(
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

  test('only private and loopback addresses count as local', () {
    expect(AiKeyReceiver.isPrivate(InternetAddress('192.168.1.20')), isTrue);
    expect(AiKeyReceiver.isPrivate(InternetAddress('10.0.0.5')), isTrue);
    expect(AiKeyReceiver.isPrivate(InternetAddress('172.20.1.1')), isTrue);
    expect(AiKeyReceiver.isPrivate(InternetAddress('172.32.1.1')), isFalse);
    expect(AiKeyReceiver.isPrivate(InternetAddress('8.8.8.8')), isFalse);
  });
}
