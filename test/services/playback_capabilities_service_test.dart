import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/playback_capabilities_service.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;

  /// An Android TV box in front of a 4K HDR TV and an Atmos soundbar, roughly.
  const shieldReply = <String, Object?>{
    'hdmiSink': true,
    'sinkEncodings': ['pcm', 'eac3-joc', 'ac3', 'eac3', 'iec61937', 'truehd', 'mystery'],
    'hdrTypes': ['hdr10', 'hlg', 'dolbyVision', 'unknown'],
    'dolbyVision': {'decoder': true, 'profile5': true, 'profile7': false, 'profile8': true, 'p7Conversion': true},
  };

  /// Answers `getPlaybackCapabilities` with [reply] (a value, a
  /// [PlatformException] to throw, or null for an unimplemented channel) and
  /// counts the calls.
  List<String> fakeChannel(Object? Function() reply) {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(playbackCapabilitiesChannel, (call) async {
      calls.add(call.method);
      final value = reply();
      if (value == null) throw MissingPluginException();
      if (value is PlatformException) throw value;
      return value;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(playbackCapabilitiesChannel, null));
    return calls;
  }

  /// What the Android side does on an HDMI route change.
  Future<void> pushInvalidate() async {
    final completer = Completer<void>();
    await messenger.handlePlatformMessage(
      playbackCapabilitiesChannel.name,
      const StandardMethodCodec().encodeMethodCall(const MethodCall('onInvalidated')),
      (_) => completer.complete(),
    );
    await completer.future;
  }

  PlaybackCapabilitiesService makeService({HardwareVideoDecode video = (hevc: true, av1: false)}) {
    final service = PlaybackCapabilitiesService(readVideoDecode: () async => video);
    addTearDown(service.dispose);
    return service;
  }

  group('PlaybackCapabilities.fromPlatform', () {
    test('parses sink encodings, HDR types and DV decoders, dropping unknown names', () {
      final caps = PlaybackCapabilities.fromPlatform(shieldReply, hardwareHevc: true, hardwareAv1: false);

      expect(caps.probed, isTrue);
      expect(caps.hdmiSink, isTrue);
      expect(caps.sinkAudioEncodings, {
        SinkAudioEncoding.pcm,
        SinkAudioEncoding.eac3Joc,
        SinkAudioEncoding.ac3,
        SinkAudioEncoding.eac3,
        SinkAudioEncoding.iec61937,
        SinkAudioEncoding.truehd,
      });
      expect(caps.displayHdrTypes, {DisplayHdrType.hdr10, DisplayHdrType.hlg, DisplayHdrType.dolbyVision});
      expect(
        caps.dolbyVision,
        const DolbyVisionDecoders(decoder: true, profile5: true, profile8: true, p7Conversion: true),
      );
      expect(caps.hardwareHevc, isTrue);
      expect(caps.hardwareAv1, isFalse);
      expect(caps.displaysHdr, isTrue);
      expect(caps.displaysDolbyVision, isTrue);
      expect(
        caps.describe(),
        'hdmi=[pcm,eac3-joc,ac3,eac3,iec61937,truehd] hdr=[hdr10,hlg,dolbyVision] '
        'hevc=hw av1=none dv=p5,p8,p7to81',
      );
    });

    test('a described sink answers yes or no per codec', () {
      final caps = PlaybackCapabilities.fromPlatform(shieldReply);

      expect(caps.sinkDescribed, isTrue);
      expect(caps.sinkTakes(SinkAudioEncoding.truehd), isTrue);
      expect(caps.sinkTakes(SinkAudioEncoding.dts), isFalse);
    });

    test('a sink listing only pcm and the IEC transport is undescribed: unknown, not no', () {
      final caps = PlaybackCapabilities.fromPlatform(const {
        'hdmiSink': true,
        'sinkEncodings': ['pcm', 'iec61937'],
      });

      expect(caps.sinkDescribed, isFalse);
      expect(caps.sinkTakes(SinkAudioEncoding.eac3), isNull);
    });

    test('no HDMI sink (optical, Bluetooth) answers unknown for every codec', () {
      final caps = PlaybackCapabilities.fromPlatform(const {'hdmiSink': false, 'sinkEncodings': <String>[]});

      expect(caps.sinkTakes(SinkAudioEncoding.ac3), isNull);
      expect(caps.displaysHdr, isFalse);
      expect(caps.describe(), startsWith('hdmi=none hdr=[]'));
    });

    test('unknown capabilities never claim a no', () {
      const caps = PlaybackCapabilities.unknown();

      expect(caps.probed, isFalse);
      expect(caps.sinkTakes(SinkAudioEncoding.truehd), isNull);
      expect(caps.displaysHdr, isNull);
      expect(caps.displaysDolbyVision, isNull);
      expect(caps.describe(), 'unprobed hevc=unknown av1=unknown');
    });
  });

  group('PlaybackCapabilitiesService', () {
    test('reads the platform once and serves later calls from memory', () async {
      final calls = fakeChannel(() => shieldReply);
      final service = makeService();

      final first = await service.getPlaybackCapabilities();
      final second = await service.getPlaybackCapabilities();

      expect(calls, ['getPlaybackCapabilities']);
      expect(identical(first, second), isTrue);
      expect(service.cached, same(first));
      expect(first.hardwareHevc, isTrue);
      expect(first.hardwareAv1, isFalse);
      expect(first.sinkTakes(SinkAudioEncoding.truehd), isTrue);
    });

    test('concurrent callers share one platform read', () async {
      final calls = fakeChannel(() => shieldReply);
      final service = makeService();

      final results = await Future.wait([service.getPlaybackCapabilities(), service.getPlaybackCapabilities()]);

      expect(calls, hasLength(1));
      expect(results.first, results.last);
    });

    test('an HDMI route change pushed from Android drops the cache and the next call reads again', () async {
      var reply = shieldReply;
      final calls = fakeChannel(() => reply);
      final service = makeService();
      final invalidations = <void>[];
      final sub = service.invalidations.listen(invalidations.add);
      addTearDown(sub.cancel);

      final before = await service.getPlaybackCapabilities();
      expect(before.sinkTakes(SinkAudioEncoding.truehd), isTrue);

      // The soundbar is switched off: the TV alone takes only (E-)AC-3.
      reply = const {
        'hdmiSink': true,
        'sinkEncodings': ['pcm', 'ac3', 'eac3'],
        'hdrTypes': ['hdr10'],
      };
      await pushInvalidate();
      await Future<void>.delayed(Duration.zero);

      expect(service.cached, isNull);
      expect(invalidations, hasLength(1));
      final after = await service.getPlaybackCapabilities();
      expect(calls, hasLength(2));
      expect(after.sinkTakes(SinkAudioEncoding.truehd), isFalse);
      expect(after.displaysDolbyVision, isFalse);
    });

    test('a read in flight when the route changes does not fill the cache with the old answer', () async {
      final gate = Completer<Object?>();
      var callCount = 0;
      messenger.setMockMethodCallHandler(playbackCapabilitiesChannel, (call) async {
        callCount++;
        if (callCount == 1) return gate.future;
        return const {
          'hdmiSink': true,
          'sinkEncodings': ['pcm', 'ac3'],
        };
      });
      addTearDown(() => messenger.setMockMethodCallHandler(playbackCapabilitiesChannel, null));
      final service = makeService();

      final stale = service.getPlaybackCapabilities();
      await Future<void>.delayed(Duration.zero);
      service.invalidate();
      gate.complete(shieldReply);
      await stale;

      expect(service.cached, isNull);
      final fresh = await service.getPlaybackCapabilities();
      expect(callCount, 2);
      expect(fresh.sinkTakes(SinkAudioEncoding.truehd), isFalse);
    });

    test('an unimplemented channel (not Android) caches unknown with the decoder probe kept', () async {
      final calls = fakeChannel(() => null);
      final service = makeService(video: (hevc: null, av1: null));

      final caps = await service.getPlaybackCapabilities();
      await service.getPlaybackCapabilities();

      expect(caps.probed, isFalse);
      expect(caps.hardwareHevc, isNull);
      expect(calls, hasLength(1));
    });

    test('a failed platform read returns unknown and retries on the next call', () async {
      var fail = true;
      final calls = fakeChannel(() => fail ? PlatformException(code: 'boom') : shieldReply);
      final service = makeService();

      final failed = await service.getPlaybackCapabilities();
      expect(failed.probed, isFalse);
      expect(failed.hardwareHevc, isTrue);
      expect(service.cached, isNull);

      fail = false;
      final retried = await service.getPlaybackCapabilities();
      expect(retried.probed, isTrue);
      expect(calls, hasLength(2));
    });

    test('a throwing decoder probe still answers, with decoders unknown', () async {
      fakeChannel(() => shieldReply);
      final service = PlaybackCapabilitiesService(readVideoDecode: () async => throw StateError('no probe'));
      addTearDown(service.dispose);

      final caps = await service.getPlaybackCapabilities();

      expect(caps.probed, isTrue);
      expect(caps.hardwareHevc, isNull);
      expect(caps.hardwareAv1, isNull);
    });
  });
}
