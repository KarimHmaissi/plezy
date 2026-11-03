import 'package:flutter/material.dart';

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
    this.headerGap = 14,
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

  /// Extra space under a page's top bar on phones, before its first row
  /// (about 36 dp from the bar to the first row title in all).
  final double headerGap;

  /// Space between neighbouring cards.
  final double cardGap;

  /// Row (section) title size; titles are semibold ([titleStyle]).
  final double titleSize;

  /// The row-title style: Plex's balance of a modest, semibold heading over
  /// the cards (TV keeps its own 26/w700 shelf titles).
  TextStyle? titleStyle(BuildContext context) =>
      Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: titleSize, fontWeight: FontWeight.w600);

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
    titleSize: 17,
    postersAcross: 3.2,
    widesAcross: 1.7,
  );

  /// Unfolded Fold / tablet.
  static const tablet = ForkSpacing(
    edgeInset: 28,
    rowGap: 32,
    titleGap: 12,
    cardGap: 14,
    titleSize: 19,
    postersAcross: 5.3,
    widesAcross: 3.2,
  );

  /// Desktop window (not TV mode).
  static const desktop = ForkSpacing(
    edgeInset: 32,
    rowGap: 32,
    titleGap: 12,
    cardGap: 16,
    titleSize: 20,
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
