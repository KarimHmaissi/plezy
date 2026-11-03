import 'package:flutter/material.dart';

import '../utils/platform_detector.dart';
import 'rasterized_gradient.dart';

/// Top-edge fade behind a toolbar that floats over content, keeping its
/// glyphs legible against artwork without a solid chrome bar.
///
/// The fade is pure black on dark schemes — a tinted surface reads as haze
/// over backdrop artwork — and the scheme surface otherwise. [child] is laid
/// out below the status bar and inside the side insets (a landscape notch, or
/// iPhone Duo's portrait sensor column) with the standard chrome insets; the
/// fade itself stays full-bleed.
///
/// Fork: on phones a fade let scrolled row titles show through the toolbar,
/// so there it's solid: from the start, or, given [scrollController], as
/// soon as the content scrolls (keeping hero artwork under it at the top).
class ToolbarScrim extends StatelessWidget {
  const ToolbarScrim({super.key, required this.child, this.scrollController});

  final Widget child;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    final safePadding = MediaQuery.paddingOf(context);
    final colorScheme = Theme.of(context).colorScheme;
    final overlayColor = colorScheme.brightness == Brightness.dark ? Colors.black : colorScheme.surface;
    final scrim = _fade(overlayColor, safePadding);
    if (PlatformDetector.isTV() || !PlatformDetector.isMobile(context)) return scrim;
    final controller = scrollController;
    final solid = ColoredBox(color: Theme.of(context).scaffoldBackgroundColor, child: scrim);
    if (controller == null) return solid;
    // Only the backing fades in; the toolbar itself is built once (it can
    // carry a GlobalKey).
    return Stack(
      children: [
        Positioned.fill(
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              final offset = controller.hasClients && controller.positions.length == 1 ? controller.offset : 0.0;
              return AnimatedOpacity(
                opacity: offset > 24 ? 1 : 0,
                duration: const Duration(milliseconds: 180),
                child: ColoredBox(color: Theme.of(context).scaffoldBackgroundColor),
              );
            },
          ),
        ),
        scrim,
      ],
    );
  }

  Widget _fade(Color overlayColor, EdgeInsets safePadding) {
    return RasterizedGradient(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          overlayColor.withValues(alpha: 0.7),
          overlayColor.withValues(alpha: 0.5),
          overlayColor.withValues(alpha: 0.3),
          Colors.transparent,
        ],
        stops: const [0.0, 0.3, 0.6, 1.0],
      ),
      child: Padding(
        padding: EdgeInsets.only(
          top: safePadding.top + 8,
          left: safePadding.left + 16,
          right: safePadding.right + 16,
          bottom: 16,
        ),
        child: child,
      ),
    );
  }
}
