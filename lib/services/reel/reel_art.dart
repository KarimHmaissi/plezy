import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// The Reel's own decoded art (plan V2-05).
///
/// The backdrops and stills the Reel builds are recorded here ([track]), and
/// [evict] drops them from Flutter's image cache when the Reel is suspended
/// (tab hidden, Watch, app paused), so art nobody is looking at any more
/// doesn't keep holding the cache that Home's artwork shares.
///
/// Two things are never evicted:
/// - Art that was already in the cache when the Reel first asked for it. It
///   belongs to someone else (Home's spotlight on the same title), and
///   dropping it would make Home decode it again after Back.
/// - Art a mounted widget is still showing (`includeLive: false`). That
///   widget keeps its image; the Reel's next build of the card decodes it
///   again from the disk cache, with no network fetch.
///
/// Anything that precaches Reel art must [track] the provider before it
/// precaches, or the card's own build finds it cached and leaves it to the
/// cache's LRU.
abstract final class ReelArt {
  /// Cache keys the Reel added, oldest first.
  static final _own = <Object>{};

  /// Cache keys that were already cached when the Reel first asked.
  static final _foreign = <Object>{};

  /// Enough for a long session's cards and their rotating backdrops; past
  /// it the oldest key is simply forgotten and left to the LRU.
  static const _limit = 256;

  /// Records [provider], built for a Reel card. Cheap enough to call on
  /// every build: server art resolves its key synchronously.
  static void track(ImageProvider provider) {
    provider.obtainKey(ImageConfiguration.empty).then<void>(_record, onError: (Object _) {});
  }

  static void _record(Object key) {
    if (_own.contains(key) || _foreign.contains(key)) return;
    final status = PaintingBinding.instance.imageCache.statusForKey(key);
    final set = status.untracked ? _own : _foreign;
    set.add(key);
    if (set.length > _limit) set.remove(set.first);
  }

  /// Drops the Reel's art from the image cache; returns how many entries
  /// went. Art still on screen stays tracked, so its next build is still
  /// the Reel's own.
  static int evict() {
    _foreign.clear();
    if (_own.isEmpty) return 0;
    final cache = PaintingBinding.instance.imageCache;
    var evicted = 0;
    for (final key in _own.toList()) {
      if (cache.evict(key, includeLive: false)) evicted++;
      if (!cache.statusForKey(key).live) _own.remove(key);
    }
    return evicted;
  }

  @visibleForTesting
  static int get trackedCount => _own.length;

  @visibleForTesting
  static void resetForTesting() {
    _own.clear();
    _foreign.clear();
  }
}
