import 'package:flutter/widgets.dart';

import '../utils/platform_detector.dart';

/// Fork: the spacing rhythm of rows of cards (Home, AI, Explore...), per
/// form factor, modelled on Plex's mobile app: an even left edge shared by
/// row titles and first cards, air between rows, bold row titles.
///
/// TV keeps its own shelf metrics ([TvLayoutConstants]); these cover touch
/// screens.
class ForkSpacing {
  const ForkSpacing({
    required this.edgeInset,
    required this.rowGap,
    required this.titleGap,
    required this.cardGap,
    required this.titleSize,
    required this.postersAcross,
    required this.widesAcross,
  });

  /// Left/right inset of row titles and the first card.
  final double edgeInset;

  /// Space after a row (below its cards' text) before the next title.
  final double rowGap;

  /// Space between a row's title and its cards.
  final double titleGap;

  /// Space between neighbouring cards.
  final double cardGap;

  final double titleSize;

  /// How many poster (2:3) / wide (16:9) cards fit across, including a peek
  /// of the next one so the row reads as scrollable.
  final double postersAcross;
  final double widesAcross;

  /// Folded phone: about three posters across.
  static const phone = ForkSpacing(
    edgeInset: 20,
    rowGap: 36,
    titleGap: 10,
    cardGap: 12,
    titleSize: 20,
    postersAcross: 3.2,
    widesAcross: 1.7,
  );

  /// Unfolded Fold / tablet.
  static const tablet = ForkSpacing(
    edgeInset: 28,
    rowGap: 32,
    titleGap: 12,
    cardGap: 14,
    titleSize: 22,
    postersAcross: 5.3,
    widesAcross: 3.2,
  );

  /// Desktop window (not TV mode).
  static const desktop = ForkSpacing(
    edgeInset: 32,
    rowGap: 32,
    titleGap: 12,
    cardGap: 16,
    titleSize: 22,
    postersAcross: 7.3,
    widesAcross: 4.3,
  );

  static ForkSpacing of(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (PlatformDetector.isDesktopOS() && width >= 900) return desktop;
    return width >= 600 ? tablet : phone;
  }

  /// Card width so [across] cards (gaps included) fill [availableWidth].
  double cardWidth(double availableWidth, {required bool wide}) {
    final across = wide ? widesAcross : postersAcross;
    final usable = availableWidth - edgeInset;
    return (usable / across) - cardGap;
  }
}
