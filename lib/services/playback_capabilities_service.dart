import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../utils/app_logger.dart';
import 'video_decode_capabilities.dart';

/// Android's `com.plezy/playback_capabilities` channel
/// (`PlaybackCapabilitiesChannel.kt`). Other platforms leave it unimplemented.
const MethodChannel playbackCapabilitiesChannel = MethodChannel('com.plezy/playback_capabilities');

/// An encoding an HDMI sink lists (`AudioDeviceInfo.getEncodings()`), by the
/// wire name the Android side sends.
enum SinkAudioEncoding {
  pcm('pcm'),
  ac3('ac3'),
  eac3('eac3'),
  eac3Joc('eac3-joc'),
  ac4('ac4'),
  truehd('truehd'),
  dolbyMat('dolby-mat'),
  dts('dts'),
  dtsHd('dts-hd'),
  dtsHdMa('dts-hd-ma'),
  dtsUhd('dts-uhd'),

  /// A transport, not a codec: it says the sink takes IEC 61937 bitstreams
  /// without saying which.
  iec61937('iec61937');

  const SinkAudioEncoding(this.wireName);

  final String wireName;

  /// A compressed codec the sink decodes itself (not PCM, not the transport).
  bool get isCodec => this != pcm && this != iec61937;

  static SinkAudioEncoding? fromWire(Object? name) {
    for (final value in values) {
      if (value.wireName == name) return value;
    }
    return null;
  }
}

/// An HDR format the active display advertises.
enum DisplayHdrType {
  hdr10('hdr10'),
  hlg('hlg'),
  hdr10Plus('hdr10Plus'),
  dolbyVision('dolbyVision');

  const DisplayHdrType(this.wireName);

  final String wireName;

  static DisplayHdrType? fromWire(Object? name) {
    for (final value in values) {
      if (value.wireName == name) return value;
    }
    return null;
  }
}

/// The device's Dolby Vision decoders, as `DoviBridge` reports them.
@immutable
class DolbyVisionDecoders {
  const DolbyVisionDecoders({
    this.decoder = false,
    this.profile5 = false,
    this.profile7 = false,
    this.profile8 = false,
    this.p7Conversion = false,
  });

  static const none = DolbyVisionDecoders();

  /// Any native Dolby Vision decoder at all.
  final bool decoder;

  /// Single-layer IPT-PQ-c2 (profile 5) through MediaCodec.
  final bool profile5;

  /// Exact profile 7 (dual layer) advertised.
  final bool profile7;

  /// Profile 8 advertised.
  final bool profile8;

  /// The bundled DV7 to 8.1 conversion path is ready, so profile 7 can play
  /// as 8.1 on a profile-8 decoder.
  final bool p7Conversion;

  factory DolbyVisionDecoders.fromMap(Map<Object?, Object?>? map) {
    if (map == null) return none;
    return DolbyVisionDecoders(
      decoder: map['decoder'] == true,
      profile5: map['profile5'] == true,
      profile7: map['profile7'] == true,
      profile8: map['profile8'] == true,
      p7Conversion: map['p7Conversion'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DolbyVisionDecoders &&
      other.decoder == decoder &&
      other.profile5 == profile5 &&
      other.profile7 == profile7 &&
      other.profile8 == profile8 &&
      other.p7Conversion == p7Conversion;

  @override
  int get hashCode => Object.hash(decoder, profile5, profile7, profile8, p7Conversion);
}

/// What this device, its display and the HDMI sink behind it can play.
///
/// Read-only facts for callers that judge a copy before opening it (Best
/// Copy's playability gates, The Reel's clip player). Nothing here changes how
/// a stream opens. Questions the device could not answer come back as null so a
/// caller can tell "no" from "don't know" and never gate on missing data.
@immutable
class PlaybackCapabilities {
  const PlaybackCapabilities({
    required this.probed,
    this.hdmiSink = false,
    this.sinkAudioEncodings = const {},
    this.displayHdrTypes = const {},
    this.hardwareHevc,
    this.hardwareAv1,
    this.dolbyVision = DolbyVisionDecoders.none,
  });

  /// Nothing measured: not Android, or the native side failed.
  const PlaybackCapabilities.unknown({this.hardwareHevc, this.hardwareAv1})
    : probed = false,
      hdmiSink = false,
      sinkAudioEncodings = const {},
      displayHdrTypes = const {},
      dolbyVision = DolbyVisionDecoders.none;

  /// Parses the `getPlaybackCapabilities` reply. Unknown names are dropped.
  factory PlaybackCapabilities.fromPlatform(Map<Object?, Object?> map, {bool? hardwareHevc, bool? hardwareAv1}) {
    final encodings = map['sinkEncodings'];
    final hdrTypes = map['hdrTypes'];
    final dolbyVision = map['dolbyVision'];
    return PlaybackCapabilities(
      probed: true,
      hdmiSink: map['hdmiSink'] == true,
      sinkAudioEncodings: {if (encodings is List) ...encodings.map(SinkAudioEncoding.fromWire).nonNulls},
      displayHdrTypes: {if (hdrTypes is List) ...hdrTypes.map(DisplayHdrType.fromWire).nonNulls},
      hardwareHevc: hardwareHevc,
      hardwareAv1: hardwareAv1,
      dolbyVision: DolbyVisionDecoders.fromMap(dolbyVision is Map ? dolbyVision : null),
    );
  }

  /// Whether the Android side answered at all.
  final bool probed;

  /// Whether a movie plays out through HDMI (false on optical, USB or
  /// Bluetooth routes, and when unprobed).
  final bool hdmiSink;

  /// Everything the movie-route HDMI sinks list.
  final Set<SinkAudioEncoding> sinkAudioEncodings;

  /// The HDR formats the active display advertises.
  final Set<DisplayHdrType> displayHdrTypes;

  /// Hardware HEVC / AV1 decode, from [VideoDecodeCapabilities]. Null when
  /// that probe never answered.
  final bool? hardwareHevc;
  final bool? hardwareAv1;

  final DolbyVisionDecoders dolbyVision;

  /// Whether the sink lists any compressed codec. Some HALs report only
  /// `pcm16|iec61937` for a sink that does decode E-AC3 (#1458), so a sink
  /// that names no codec says nothing about which ones it takes.
  bool get sinkDescribed => sinkAudioEncodings.any((encoding) => encoding.isCodec);

  /// Whether the HDMI sink takes [encoding]: null when that cannot be known
  /// (unprobed, no HDMI sink, or a sink that names no codec).
  bool? sinkTakes(SinkAudioEncoding encoding) {
    if (!probed || !hdmiSink || !sinkDescribed) return null;
    return sinkAudioEncodings.contains(encoding);
  }

  /// Whether the display shows HDR10/HLG/HDR10+/DV; null when unprobed.
  bool? get displaysHdr => probed ? displayHdrTypes.isNotEmpty : null;

  /// Whether the display shows Dolby Vision; null when unprobed.
  bool? get displaysDolbyVision => probed ? displayHdrTypes.contains(DisplayHdrType.dolbyVision) : null;

  /// One line for logs, e.g.
  /// `hdmi=[pcm,eac3-joc,ac3] hdr=[hdr10,hlg] hevc=hw av1=none dv=p5,p8`.
  String describe() {
    if (!probed) return 'unprobed hevc=${_hw(hardwareHevc)} av1=${_hw(hardwareAv1)}';
    final sink = hdmiSink ? '[${sinkAudioEncodings.map((e) => e.wireName).join(',')}]' : 'none';
    final dv = [
      if (dolbyVision.profile5) 'p5',
      if (dolbyVision.profile7) 'p7',
      if (dolbyVision.profile8) 'p8',
      if (dolbyVision.p7Conversion) 'p7to81',
    ];
    return 'hdmi=$sink hdr=[${displayHdrTypes.map((t) => t.wireName).join(',')}] '
        'hevc=${_hw(hardwareHevc)} av1=${_hw(hardwareAv1)} '
        'dv=${dv.isEmpty ? (dolbyVision.decoder ? 'decoder' : 'none') : dv.join(',')}';
  }

  static String _hw(bool? value) => value == null ? 'unknown' : (value ? 'hw' : 'none');

  @override
  bool operator ==(Object other) =>
      other is PlaybackCapabilities &&
      other.probed == probed &&
      other.hdmiSink == hdmiSink &&
      setEquals(other.sinkAudioEncodings, sinkAudioEncodings) &&
      setEquals(other.displayHdrTypes, displayHdrTypes) &&
      other.hardwareHevc == hardwareHevc &&
      other.hardwareAv1 == hardwareAv1 &&
      other.dolbyVision == dolbyVision;

  @override
  int get hashCode => Object.hash(
    probed,
    hdmiSink,
    Object.hashAllUnordered(sinkAudioEncodings),
    Object.hashAllUnordered(displayHdrTypes),
    hardwareHevc,
    hardwareAv1,
    dolbyVision,
  );
}

/// Hardware HEVC / AV1 decode support; null means "not measured".
typedef HardwareVideoDecode = ({bool? hevc, bool? av1});

/// Reads [PlaybackCapabilities] once and keeps it in memory until the Android
/// side reports an HDMI route change (`onInvalidated`), then reads again on
/// next use. Standalone on purpose: not wired into the player, so a picker or
/// a clip player can ask without opening one.
class PlaybackCapabilitiesService {
  /// [readVideoDecode] stands in for the [VideoDecodeCapabilities] probe in
  /// tests.
  PlaybackCapabilitiesService({Future<HardwareVideoDecode> Function()? readVideoDecode})
    : _readVideoDecode = readVideoDecode ?? _probeVideoDecode {
    _channel.setMethodCallHandler(_onPlatformCall);
  }

  static PlaybackCapabilitiesService? _instance;

  /// The app-wide service, created on first use.
  static PlaybackCapabilitiesService get instance => _instance ??= PlaybackCapabilitiesService();

  static const MethodChannel _channel = playbackCapabilitiesChannel;
  final Future<HardwareVideoDecode> Function() _readVideoDecode;
  final StreamController<void> _invalidations = StreamController<void>.broadcast();

  PlaybackCapabilities? _cached;
  Future<PlaybackCapabilities>? _inFlight;

  /// Bumped by [invalidate], so a read that started before it never fills the
  /// cache with the old route's answer.
  int _generation = 0;

  /// The last answer, or null before the first read and after an invalidation.
  PlaybackCapabilities? get cached => _cached;

  /// Fires after each invalidation, so a caller holding a ranked list can
  /// rank it again.
  Stream<void> get invalidations => _invalidations.stream;

  /// The capabilities, from memory when nothing has changed since the last
  /// read. Never throws: a failed read returns [PlaybackCapabilities.unknown]
  /// and is retried on the next call.
  Future<PlaybackCapabilities> getPlaybackCapabilities() {
    final cached = _cached;
    if (cached != null) return Future.value(cached);
    return _inFlight ??= _read();
  }

  /// Drops the cached answer; the next [getPlaybackCapabilities] reads again.
  void invalidate() {
    _generation++;
    _cached = null;
    _inFlight = null;
    _invalidations.add(null);
  }

  Future<PlaybackCapabilities> _read() async {
    final generation = _generation;
    HardwareVideoDecode video;
    try {
      video = await _readVideoDecode();
    } catch (error) {
      appLogger.w('Video decode probe failed', error: error);
      video = (hevc: null, av1: null);
    }
    PlaybackCapabilities result;
    var cacheable = true;
    try {
      final map = await _channel.invokeMapMethod<Object?, Object?>('getPlaybackCapabilities');
      result = map == null
          ? PlaybackCapabilities.unknown(hardwareHevc: video.hevc, hardwareAv1: video.av1)
          : PlaybackCapabilities.fromPlatform(map, hardwareHevc: video.hevc, hardwareAv1: video.av1);
    } on MissingPluginException {
      // Not Android, or a stale native build: the answer won't change.
      result = PlaybackCapabilities.unknown(hardwareHevc: video.hevc, hardwareAv1: video.av1);
    } on PlatformException catch (error) {
      appLogger.w('Playback capabilities read failed', error: error);
      result = PlaybackCapabilities.unknown(hardwareHevc: video.hevc, hardwareAv1: video.av1);
      cacheable = false;
    }
    if (generation == _generation) {
      _inFlight = null;
      if (cacheable) _cached = result;
    }
    return result;
  }

  Future<Object?> _onPlatformCall(MethodCall call) async {
    if (call.method == 'onInvalidated') invalidate();
    return null;
  }

  static Future<HardwareVideoDecode> _probeVideoDecode() async {
    await VideoDecodeCapabilities.getInstance();
    return (
      hevc: VideoDecodeCapabilities.hardwareDecodes(RankedVideoCodec.hevc),
      av1: VideoDecodeCapabilities.hardwareDecodes(RankedVideoCodec.av1),
    );
  }

  /// Detaches from the channel. For tests and a replaced [instance].
  void dispose() {
    _channel.setMethodCallHandler(null);
    _invalidations.close();
  }

  @visibleForTesting
  static void debugReset() {
    _instance?.dispose();
    _instance = null;
  }
}
