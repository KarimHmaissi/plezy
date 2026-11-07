/// Fork (Reel, plan V2-16): one place for the per-device playback rules. A
/// profile is a plain value built from the device (TV or not), the screen's
/// size and pixel ratio, its orientation, the network link and the data
/// saver pref. The app rebuilds it when the screen's metrics change (a
/// foldable switching screens) and the resolver applies it when a card plays,
/// so the clip's file is picked at play time, never baked into the cache.
/// Pure, so the rules are unit-tested.
library;

import 'dart:math' as math;

import 'package:flutter/painting.dart' show BoxFit, Size;

/// Which rule set applies.
enum ReelScreen {
  /// A TV: up to 1080, SDR only, the highest bitrate at that height.
  tv,

  /// A small screen held upright (a foldable's cover screen, a phone): up to
  /// 720, fill allowed.
  compactPortrait,

  /// A large screen, or any screen turned sideways (a foldable's inner
  /// screen): 1080 on Wi-Fi, 720 on mobile data.
  large,
}

/// The network the clip would stream over.
enum ReelLink {
  /// Wi-Fi, Ethernet, or unknown (the app assumes online and unmetered).
  unmetered,

  /// Mobile data.
  cellular,

  /// No network at all.
  offline,
}

/// One file of a clip a profile can choose between: the same clip at
/// another height or size.
abstract interface class ReelRendition {
  /// The picture's height in lines (720, 1080); null when unknown.
  int? get height;

  /// The file's size in bytes; null when unknown.
  int? get sizeBytes;

  /// The source's own preference apart from height under [profile], lower
  /// first (an opening with no episode footage before one with a
  /// transition, creditless before credited, captions as the profile asks).
  /// Only the best rank is played; the profile picks among files of that
  /// rank.
  int rankFor(ReelPlaybackProfile profile);
}

class ReelPlaybackProfile {
  const ReelPlaybackProfile({
    required this.screen,
    required this.maxHeight,
    this.link = ReelLink.unmetered,
    this.dataSaver = false,
    this.sdrOnly = false,
    this.fit = BoxFit.contain,
    this.fillAllowed = false,
    this.largerFileAtHeight = true,
    this.captions = false,
  });

  /// The rules for [screen] on [link], with the height cap lowered to what
  /// a screen of [size] (logical pixels) at [devicePixelRatio] can show of a
  /// 16:9 picture, and to [dataSaverHeight] when [dataSaver] is on over
  /// mobile data. A zero [size] (no view yet) leaves the rule's cap.
  /// [captions] ranks openings with lyrics or subtitles first (V2-54).
  factory ReelPlaybackProfile.from({
    required bool tv,
    required Size size,
    required double devicePixelRatio,
    required ReelLink link,
    bool dataSaver = false,
    bool captions = false,
  }) {
    final portrait = size.height > size.width;
    final screen = tv
        ? ReelScreen.tv
        : (size.shortestSide < compactBreakpoint && portrait && !size.isEmpty)
        ? ReelScreen.compactPortrait
        : ReelScreen.large;
    final cellular = link == ReelLink.cellular;
    final saving = dataSaver && cellular;
    var cap = switch (screen) {
      ReelScreen.tv => 1080,
      ReelScreen.compactPortrait => 720,
      ReelScreen.large => cellular ? 720 : 1080,
    };
    final shown = _shownHeight(size, devicePixelRatio);
    if (shown != null) cap = math.min(cap, shown);
    if (saving) cap = math.min(cap, dataSaverHeight);
    return ReelPlaybackProfile(
      screen: screen,
      maxHeight: cap,
      link: link,
      dataSaver: saving,
      sdrOnly: screen == ReelScreen.tv,
      fillAllowed: screen == ReelScreen.compactPortrait,
      largerFileAtHeight: !saving,
      captions: captions,
    );
  }

  /// Before the app has measured anything (and in tests): the large-screen
  /// rule on an unmetered link.
  static const ReelPlaybackProfile standard = ReelPlaybackProfile(screen: ReelScreen.large, maxHeight: 1080);

  /// The shortest side below which a screen is compact: the app's own
  /// phone/tablet split (ForkSpacing.of).
  static const double compactBreakpoint = 600;

  /// The height cap with data saver on over mobile data (V2-53).
  static const int dataSaverHeight = 480;

  /// The clip heights the screen cap rounds up to.
  static const List<int> ladder = [360, 480, 720, 1080];

  final ReelScreen screen;

  /// The tallest picture worth streaming. A clip with no file at or below
  /// it plays its smallest height above it.
  final int maxHeight;
  final ReelLink link;

  /// Data saver is on and the link is mobile data.
  final bool dataSaver;

  /// Never HDR or Dolby Vision output (the clip core enforces it, V2-18).
  final bool sdrOnly;

  /// How the clip sits in its frame: whole, letterboxed if need be.
  final BoxFit fit;

  /// The viewer may switch to filling the frame (cropping the picture).
  final bool fillAllowed;

  /// At the chosen height, the larger file (the higher bitrate) wins; with
  /// data saver the smaller one does.
  final bool largerFileAtHeight;

  /// The viewer wants captions: a file with lyrics or dialogue subtitles
  /// ranks before one without (V2-54, V2-17). Off, the clean file ranks
  /// first.
  final bool captions;

  /// The height this profile plays from [heights]: the tallest at or below
  /// [maxHeight], else the shortest above it. Null for no heights.
  int? heightFrom(Iterable<int> heights) {
    int? below, above;
    for (final h in heights) {
      if (h <= maxHeight) {
        if (below == null || h > below) below = h;
      } else if (above == null || h < above) {
        above = h;
      }
    }
    return below ?? above;
  }

  /// The file to play from [renditions]: the best [ReelRendition.rankFor],
  /// then [heightFrom] (a file of unknown height only when no height is
  /// known), then the larger or smaller file by [largerFileAtHeight]. Ties
  /// keep the source's order. Null for none.
  T? pick<T extends ReelRendition>(Iterable<T> renditions) {
    final all = renditions.toList();
    if (all.isEmpty) return null;
    final ranks = [for (final r in all) r.rankFor(this)];
    final best = ranks.reduce(math.min);
    final ranked = [
      for (var i = 0; i < all.length; i++)
        if (ranks[i] == best) all[i],
    ];
    final height = heightFrom([for (final r in ranked) ?r.height]);
    final atHeight = [
      for (final r in ranked)
        if (r.height == height) r,
    ];
    T? chosen;
    for (final r in atHeight) {
      if (chosen == null || _better(r.sizeBytes, chosen.sizeBytes)) chosen = r;
    }
    return chosen;
  }

  /// Whether a file of [size] beats the current choice of [current]; an
  /// unknown size never beats a known one.
  bool _better(int? size, int? current) {
    if (size == null) return false;
    if (current == null) return true;
    return largerFileAtHeight ? size > current : size < current;
  }

  /// The height in device pixels of a 16:9 picture fitted to the screen,
  /// rounded up to the [ladder]; null when the screen is unmeasured or
  /// taller than the ladder.
  static int? _shownHeight(Size size, double devicePixelRatio) {
    if (size.isEmpty || devicePixelRatio <= 0) return null;
    final w = size.width * devicePixelRatio, h = size.height * devicePixelRatio;
    final shown = math.min(w * 9 / 16, h);
    // A pixel or two under a step (1078 on a 1080 panel) is that step.
    return ladder.where((step) => step >= shown - 2).firstOrNull;
  }

  @override
  bool operator ==(Object other) =>
      other is ReelPlaybackProfile &&
      other.screen == screen &&
      other.maxHeight == maxHeight &&
      other.link == link &&
      other.dataSaver == dataSaver &&
      other.sdrOnly == sdrOnly &&
      other.fit == fit &&
      other.fillAllowed == fillAllowed &&
      other.largerFileAtHeight == largerFileAtHeight &&
      other.captions == captions;

  @override
  int get hashCode =>
      Object.hash(screen, maxHeight, link, dataSaver, sdrOnly, fit, fillAllowed, largerFileAtHeight, captions);

  @override
  String toString() =>
      'ReelPlaybackProfile(${screen.name}, ≤$maxHeight, ${link.name}'
      '${dataSaver ? ', data saver' : ''}${sdrOnly ? ', SDR' : ''}${captions ? ', captions' : ''})';
}
