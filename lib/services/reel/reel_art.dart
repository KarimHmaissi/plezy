import 'package:flutter/widgets.dart';

import '../../utils/app_logger.dart';
import '../device_performance.dart';
import '../memory_trim_policy.dart';

/// The Reel's own decoded art (plans V2-05 and §6).
///
/// The backdrops, stills, logos and tiles the Reel builds are recorded here
/// ([track]), with the card each one belongs to when there is one. Two
/// things then keep them from crowding out the cache that Home's artwork
/// shares:
///
/// - **The budget, while the Reel is the active tab.** The controller tells
///   [keep] the cards around the one on screen, nearest first (its prefetch
///   window). Whenever the Reel's art held in the image cache is over
///   [budgetBytes], [trim] evicts it oldest first: art of cards that left the
///   window, then the window's farthest cards; never the card on screen.
/// - **Suspend** (tab hidden, Watch, app paused): [evict] drops all of it and
///   turns the budget off until the next [keep].
///
/// The budget is the plan's §6 share (`DevicePerformance.reelImageBudgetBytes`)
/// scaled by the app's own memory trims ([MemoryTrimPolicy.scaledShare]): a
/// halved image cache halves the Reel's share too, and the policy's restore
/// brings it back.
///
/// Two things are never evicted:
/// - Art that was already in the cache when the Reel first asked for it. It
///   belongs to someone else (Home's spotlight on the same title), and
///   dropping it would make Home decode it again after Back.
/// - Art a mounted widget is still showing (`includeLive: false`). That
///   widget keeps its image; only the cache's copy goes, so the image is
///   freed when the widget lets go of it, and the Reel's next build of the
///   card decodes it again from the disk cache, with no network fetch.
///
/// Anything that precaches Reel art must [track] the provider before it
/// precaches, or the card's own build finds it cached and leaves it to the
/// cache's LRU.
abstract final class ReelArt {
  /// Cache keys the Reel added, least recently built first.
  static final _own = <Object, _Own>{};

  /// Cache keys that were already cached when the Reel first asked.
  static final _foreign = <Object>{};

  /// The cards the budget keeps, nearest first; null while the Reel is
  /// suspended (no budget).
  static List<String>? _window;

  /// Enough for a long session's cards and their rotating backdrops; past
  /// it the oldest key is simply forgotten and left to the LRU.
  static const _limit = 256;

  /// Records [provider], built for a Reel card ([card], its id) or for the
  /// Reel's other surfaces (no card). Cheap enough to call on every build:
  /// server art resolves its key synchronously.
  static void track(ImageProvider provider, {String? card}) {
    provider
        .obtainKey(ImageConfiguration.empty)
        .then<void>((key) => _record(provider, key, card), onError: (Object _) {});
  }

  /// Warms [provider] in the image cache ahead of the card that shows it
  /// (plan V2-13), tracked first so the budget and suspend still see it.
  /// Completes when the image has decoded or failed; a failure is only
  /// logged, and the card's own build tries again.
  static Future<void> precache(ImageProvider provider, BuildContext context, {String? card}) {
    track(provider, card: card);
    return precacheImage(
      provider,
      context,
      onError: (Object e, StackTrace? _) => appLogger.d('[ReelArt] precache failed (${e.runtimeType})'),
    );
  }

  /// The Reel is active with [cards] around the one on screen, nearest first
  /// (the first is the card on screen). Turns the budget on and trims to it.
  static void keep(List<String> cards) {
    _window = List.unmodifiable(cards);
    trim();
  }

  /// The image-cache bytes the Reel's art may hold now: the device's §6
  /// share, scaled to the app's current memory trim.
  static int budgetBytes() {
    final override = debugBudgetBytes;
    if (override != null) return override();
    return MemoryTrimPolicy.instance.scaledShare(DevicePerformance.reelImageBudgetBytes());
  }

  @visibleForTesting
  static int Function()? debugBudgetBytes;

  /// The bytes of the Reel's own art the image cache holds now (decoded and
  /// kept, live or not). Art still loading counts once it has decoded.
  static int get heldBytes {
    final cache = PaintingBinding.instance.imageCache;
    var held = 0;
    for (final MapEntry(:key, value: own) in _own.entries) {
      final bytes = own.bytes;
      if (bytes != null && cache.statusForKey(key).keepAlive) held += bytes;
    }
    return held;
  }

  /// Brings the Reel's art back within [budgetBytes] while the Reel is
  /// active; returns how many entries went. Art of cards outside the window
  /// and art with no card go first, least recently built first; then the
  /// window's cards from the farthest in; then whatever the card on screen
  /// built but no longer shows (a size it was laid out at before). What the
  /// card on screen shows is never trimmed: it is the budget's floor.
  static int trim() {
    final window = _window;
    if (window == null || _own.isEmpty) return 0;
    final budget = budgetBytes();
    var held = heldBytes;
    if (held <= budget) return 0;
    final cache = PaintingBinding.instance.imageCache;
    final onScreen = window.isEmpty ? null : window.first;
    Iterable<Object> keysOf(String card) => [
      for (final MapEntry(:key, value: own) in _own.entries)
        if (own.card == card) key,
    ];
    final order = [
      for (final MapEntry(:key, value: own) in _own.entries)
        if (own.card == null || !window.contains(own.card)) key,
      for (final card in window.reversed)
        if (card != onScreen) ...keysOf(card),
      if (onScreen != null)
        for (final key in keysOf(onScreen))
          if (!cache.statusForKey(key).live) key,
    ];
    var evicted = 0;
    for (final key in order) {
      if (held <= budget) break;
      final bytes = _own[key]?.bytes;
      if (bytes == null || !cache.statusForKey(key).keepAlive) continue;
      if (cache.evict(key, includeLive: false)) {
        held -= bytes;
        evicted++;
      }
      if (!cache.statusForKey(key).live) _own.remove(key);
    }
    if (evicted > 0) {
      appLogger.d(
        '[ReelArt] budget: let $evicted go, ${_mb(held)} of ${_mb(budget)} held'
        '${held > budget ? ' (the card on screen is over it by itself)' : ''}',
      );
    }
    return evicted;
  }

  static void _record(ImageProvider provider, Object key, String? card) {
    if (_foreign.contains(key)) return;
    final own = _own.remove(key);
    if (own != null) {
      // Built again: the most recent now, and the card that built it.
      _own[key] = own..card = card ?? own.card;
      return;
    }
    final status = PaintingBinding.instance.imageCache.statusForKey(key);
    if (!status.untracked) {
      _foreign.add(key);
      if (_foreign.length > _limit) _foreign.remove(_foreign.first);
      return;
    }
    _own[key] = _Own(card);
    if (_own.length > _limit) _own.remove(_own.keys.first);
    _measure(provider, key);
  }

  /// Learns [key]'s decoded size from its first frame, then trims: the
  /// cache only grows once an image has decoded.
  static void _measure(ImageProvider provider, Object key) {
    final stream = provider.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener((image, _) {
      _own[key]?.bytes = image.sizeBytes;
      image.dispose();
      stream.removeListener(listener);
      trim();
    }, onError: (Object _, StackTrace? _) => stream.removeListener(listener));
    stream.addListener(listener);
  }

  /// Drops the Reel's art from the image cache and turns the budget off
  /// until the next [keep]; returns how many entries went. Art still on
  /// screen stays tracked, so its next build is still the Reel's own.
  static int evict() {
    _window = null;
    _foreign.clear();
    if (_own.isEmpty) return 0;
    final cache = PaintingBinding.instance.imageCache;
    var evicted = 0;
    for (final key in _own.keys.toList()) {
      if (cache.evict(key, includeLive: false)) evicted++;
      if (!cache.statusForKey(key).live) _own.remove(key);
    }
    return evicted;
  }

  static String _mb(int bytes) => '${(bytes / (1 << 20)).toStringAsFixed(1)}MB';

  @visibleForTesting
  static int get trackedCount => _own.length;

  @visibleForTesting
  static String? cardOf(Object key) => _own[key]?.card;

  @visibleForTesting
  static void resetForTesting() {
    _own.clear();
    _foreign.clear();
    _window = null;
    debugBudgetBytes = null;
  }
}

/// One of the Reel's cache keys: the card it was built for, and its decoded
/// size once known.
class _Own {
  _Own(this.card);

  String? card;
  int? bytes;
}
