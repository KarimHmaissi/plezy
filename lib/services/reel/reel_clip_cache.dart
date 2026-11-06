import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../utils/app_logger.dart';

/// How full the clip disk cache is.
@immutable
class ReelClipCacheUsage {
  const ReelClipCacheUsage({required this.bytes, required this.capBytes});

  final int bytes;

  /// The cap on this device (192 MB on a TV, 256 MB elsewhere, less when the
  /// disk is nearly full; 0 when there is no room for a cache).
  final int capBytes;
}

/// The TV clip core's disk cache (plan V2-10, D1): Plex clips the core has
/// played or preloaded stay on disk (LRU, `cacheDir/reel-clips/`), so a
/// back-swipe, a Replay after Watch, a reopen or the same title in another
/// deck reads them from disk. AnimeThemes clips never go to disk, and the
/// main player never reaches it.
///
/// This is the Dart side of `ReelClipCacheChannel.kt`: the settings row's
/// usage and Clear, and which deck heads are on disk (plan D15). Off Android
/// (and when the channel is missing) every call answers "nothing".
class ReelClipCache {
  ReelClipCache({MethodChannel? channel, bool? supported, this.timeout = const Duration(seconds: 3)})
    : _channel = channel ?? defaultChannel,
      _supported = supported ?? (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  static final ReelClipCache instance = ReelClipCache();

  static const MethodChannel defaultChannel = MethodChannel('com.plezy/reel_clip_cache');

  final MethodChannel _channel;
  final bool _supported;
  final Duration timeout;

  /// Whether this device has the cache (Android).
  bool get supported => _supported;

  /// A Plex clip's cache key: the server's id and the clip file's part path.
  /// Never the clip's URL, which carries the connection address and the
  /// token: a new address or token still hits, and no token lands in the
  /// cache's index. The part's own query is kept, sorted and joined with `;`
  /// (an IVA trailer's `fmt` and `bitrate` name different bytes under one
  /// path, and the cache must never mix them), less any token parameter.
  /// Null when the part path looks like it could carry a secret (the core
  /// refuses such a key too).
  static String? keyFor(String serverId, String partKey) {
    final noFragment = partKey.split('#').first;
    final q = noFragment.indexOf('?');
    final path = q < 0 ? noFragment : noFragment.substring(0, q);
    if (serverId.isEmpty || path.isEmpty) return null;
    final params = q < 0
        ? const <String>[]
        : ([
            for (final p in noFragment.substring(q + 1).split('&'))
              if (p.isNotEmpty && !p.split('=').first.toLowerCase().contains('token')) p,
          ]..sort());
    final key = 'plex:$serverId:$path${params.map((p) => ';$p').join()}';
    if (key.toLowerCase().contains('token') || key.contains('&') || key.contains('://')) return null;
    return key;
  }

  Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    if (!_supported) return null;
    try {
      return await _channel.invokeMethod<T>(method, args).timeout(timeout);
    } on MissingPluginException {
      return null;
    } catch (e) {
      appLogger.d('[ReelCache] $method failed (${e.runtimeType})');
      return null;
    }
  }

  /// How full the cache is; null off Android or on a failure.
  Future<ReelClipCacheUsage?> usage() async {
    final raw = await _call<Map<Object?, Object?>>('usage');
    if (raw == null) return null;
    final bytes = raw['bytes'];
    final cap = raw['capBytes'];
    if (bytes is! int || cap is! int) return null;
    return ReelClipCacheUsage(bytes: bytes, capBytes: cap);
  }

  /// Empties the cache; the bytes it held, or null when it couldn't.
  Future<int?> clear() async {
    final freed = await _call<int>('clear');
    if (freed != null) appLogger.i('[ReelCache] cleared ${freed ~/ 1024}KB');
    return freed;
  }

  /// Which of [keys] have their clip on disk.
  Future<Set<String>> onDisk(Iterable<String> keys) async {
    final list = keys.toList();
    if (list.isEmpty) return const {};
    final raw = await _call<List<Object?>>('onDisk', {'keys': list});
    return {...?raw?.whereType<String>()};
  }

  /// Whether [key]'s clip is on disk (false for no key).
  Future<bool> isOnDisk(String? key) async => key != null && (await onDisk([key])).contains(key);
}
