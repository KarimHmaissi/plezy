import 'package:flutter/material.dart';

import '../../services/reel/clip_player.dart';
import '../../services/reel/reel_controller.dart';

/// The Reel's palette: a projection-booth dark with one warm lamp colour.
abstract final class ReelInk {
  static const Color lamp = Color(0xFFF2B84B);
  static const Color paper = Color(0xFFF6F1E7);
  static const Color dim = Color(0xB3F6F1E7);
  static const Color booth = Color(0xFF0B0A09);
}

/// One card: the clip shows through (the native surface sits behind
/// Flutter), with the title line above the band and the why line under it.
/// Until the first frame, and for AI cards, the real backdrop is shown as a
/// still (never panned).
class ReelCardView extends StatelessWidget {
  const ReelCardView({
    super.key,
    required this.controller,
    required this.slot,
    required this.tv,
    required this.onReplay,
    this.onWatch,
    this.onSave,
    this.onRemote,
  });

  final ReelController controller;
  final ReelSlot slot;
  final bool tv;
  final VoidCallback onReplay;
  final VoidCallback? onWatch;
  final VoidCallback? onSave;
  final VoidCallback? onRemote;

  @override
  Widget build(BuildContext context) {
    switch (slot.kind) {
      case ReelSlotKind.loading:
        return const ReelCurtain(label: 'Threading the reel');
      case ReelSlotKind.empty:
        return _Message(
          title: 'Nothing in ${controller.deck.name} yet',
          body: tv ? 'Press → for the next deck.' : 'Swipe sideways for the next deck.',
        );
      case ReelSlotKind.poolEnd:
        return _Message(
          title: controller.deck.id == 'for-you' ? "That's today's For You" : "That's all of ${controller.deck.name}",
          body: tv ? 'Press → for ${_nextDeckName()}.' : 'Swipe sideways for ${_nextDeckName()}.',
        );
      case ReelSlotKind.card:
        break;
    }
    final card = slot.card!;
    final isCurrent = identical(controller.current.card, card);
    return ValueListenableBuilder<ClipPhase>(
      valueListenable: controller.clips.phase,
      builder: (context, phase, _) {
        final showingClip =
            isCurrent &&
            slot.clip != null &&
            (phase == ClipPhase.playing || phase == ClipPhase.paused || phase == ClipPhase.held);
        final art = slot.item == null
            ? null
            : controller.media.imageUrl(
                card.best.serverId,
                slot.item!.artPath ?? slot.item!.thumbPath,
                width: tv ? 1280 : 900,
              );
        final size = MediaQuery.sizeOf(context);
        final scale = tv ? (size.width / 960).clamp(0.8, 2.0) : 1.0;
        return Stack(
          fit: StackFit.expand,
          children: [
            // Backdrop still: before the first frame, and for AI cards.
            AnimatedOpacity(
              opacity: showingClip ? 0 : 1,
              duration: const Duration(milliseconds: 320),
              child: ColoredBox(
                color: ReelInk.booth,
                child: art == null
                    ? const SizedBox.expand()
                    : Image.network(
                        art,
                        fit: BoxFit.cover,
                        cacheWidth: tv ? 1280 : 900,
                        gaplessPlayback: true,
                        errorBuilder: (_, _, _) => const SizedBox.expand(),
                      ),
              ),
            ),
            // Reading band.
            const Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: [0, 0.18, 0.62, 1],
                      colors: [Color(0x99000000), Color(0x00000000), Color(0x00000000), Color(0xE6000000)],
                    ),
                  ),
                ),
              ),
            ),
            if (slot.isAiCard && slot.item?.tagline != null)
              Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 48 * scale),
                  child: _Reveal(
                    key: ValueKey('hook:${card.id}'),
                    child: Text(
                      slot.item!.tagline!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: ReelInk.paper,
                        fontSize: (tv ? 30 : 26) * scale,
                        height: 1.15,
                        fontWeight: FontWeight.w300,
                        letterSpacing: 0.2,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                ),
              ),
            Positioned(
              left: (tv ? 56 : 20) * scale,
              right: (tv ? 56 : 20) * scale,
              bottom: (tv ? 40 : 28) * scale,
              child: _Caption(
                key: ValueKey('cap:${card.id}'),
                controller: controller,
                slot: slot,
                scale: scale,
                tv: tv,
                held: isCurrent && phase == ClipPhase.held,
                onReplay: onReplay,
                onWatch: onWatch,
                onSave: onSave,
                onRemote: onRemote,
              ),
            ),
          ],
        );
      },
    );
  }

  String _nextDeckName() {
    final d = controller.decks;
    return d.length < 2 ? 'another deck' : d[(controller.deckIndex + 1) % d.length].name;
  }
}

class _Caption extends StatelessWidget {
  const _Caption({
    super.key,
    required this.controller,
    required this.slot,
    required this.scale,
    required this.tv,
    required this.held,
    required this.onReplay,
    this.onWatch,
    this.onSave,
    this.onRemote,
  });

  final ReelController controller;
  final ReelSlot slot;
  final double scale;
  final bool tv;
  final bool held;
  final VoidCallback onReplay;
  final VoidCallback? onWatch;
  final VoidCallback? onSave;
  final VoidCallback? onRemote;

  @override
  Widget build(BuildContext context) {
    final card = slot.card!;
    final f = card.facts;
    final facts = [if (card.best.year != null) '${card.best.year}', ?f.cardLine(compact: true), ?f.lengthLine()];
    final badge = f.seen.badge;
    final chips = [
      ?card.chip,
      if (badge != null && controller.deck.keepsSeen) badge,
      if (slot.clip != null) slot.clip!.label,
    ];
    return _Reveal(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (chips.isNotEmpty)
            Wrap(
              spacing: 8 * scale,
              children: [for (final c in chips) _Chip(text: c, scale: scale)],
            ),
          SizedBox(height: 8 * scale),
          Text(
            card.title.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: ReelInk.paper,
              fontSize: (tv ? 40 : 30) * scale,
              height: 1.02,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.6,
            ),
          ),
          SizedBox(height: 6 * scale),
          Text(
            facts.join('  ·  '),
            style: TextStyle(color: ReelInk.dim, fontSize: (tv ? 15 : 14) * scale, letterSpacing: 0.4),
          ),
          if (card.why != null) ...[
            SizedBox(height: 10 * scale),
            Text(
              card.why!,
              maxLines: 2,
              style: TextStyle(
                color: ReelInk.paper,
                fontSize: (tv ? 17 : 15) * scale,
                fontStyle: FontStyle.italic,
                height: 1.3,
              ),
            ),
          ],
          if (slot.clip?.source.origin == ClipOrigin.animeTheme) ...[
            SizedBox(height: 6 * scale),
            Text(
              'Theme via AnimeThemes',
              style: TextStyle(color: ReelInk.dim, fontSize: 11 * scale, letterSpacing: 0.6),
            ),
          ],
          if (held) ...[
            SizedBox(height: 14 * scale),
            _Pill(
              label: 'Replay',
              icon: Icons.replay_rounded,
              scale: scale,
              primary: true,
              onTap: onReplay,
              autofocus: tv,
            ),
          ],
          if (!tv) ...[
            SizedBox(height: 16 * scale),
            Row(
              children: [
                _Pill(label: 'Watch on TV', icon: Icons.tv_rounded, scale: scale, primary: true, onTap: onWatch),
                const SizedBox(width: 10),
                _Pill(label: 'Save', icon: Icons.bookmark_add_outlined, scale: scale, onTap: onSave),
                if (onRemote != null) ...[
                  const SizedBox(width: 10),
                  _Pill(label: 'On TV', icon: Icons.settings_remote_rounded, scale: scale, onTap: onRemote),
                ],
              ],
            ),
          ] else
            Padding(
              padding: EdgeInsets.only(top: 14 * scale),
              child: Text(
                'OK  watch    ↓  next    →  next deck    hold OK  more',
                style: TextStyle(color: ReelInk.dim.withValues(alpha: 0.55), fontSize: 12 * scale, letterSpacing: 1.1),
              ),
            ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.text, required this.scale});

  final String text;
  final double scale;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.symmetric(horizontal: 9 * scale, vertical: 3 * scale),
    decoration: BoxDecoration(
      border: Border.all(color: ReelInk.lamp.withValues(alpha: 0.85), width: 1),
      borderRadius: BorderRadius.circular(3),
    ),
    child: Text(
      text.toUpperCase(),
      style: TextStyle(color: ReelInk.lamp, fontSize: 11 * scale, fontWeight: FontWeight.w700, letterSpacing: 1.4),
    ),
  );
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    required this.icon,
    required this.scale,
    this.primary = false,
    this.onTap,
    this.autofocus = false,
  });

  final String label;
  final IconData icon;
  final double scale;
  final bool primary;
  final VoidCallback? onTap;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => FilledButton.icon(
    autofocus: autofocus,
    onPressed: onTap,
    icon: Icon(icon, size: 18 * scale),
    label: Text(label),
    style: FilledButton.styleFrom(
      backgroundColor: primary ? ReelInk.lamp : const Color(0x33F6F1E7),
      foregroundColor: primary ? ReelInk.booth : ReelInk.paper,
      padding: EdgeInsets.symmetric(horizontal: 16 * scale, vertical: 10 * scale),
      textStyle: TextStyle(fontWeight: FontWeight.w700, fontSize: 14 * scale),
      shape: const StadiumBorder(),
    ),
  );
}

/// A soft rise-and-fade when a card's text arrives.
class _Reveal extends StatelessWidget {
  const _Reveal({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: const Duration(milliseconds: 420),
    curve: Curves.easeOutCubic,
    builder: (context, t, child) => Opacity(
      opacity: t,
      child: Transform.translate(offset: Offset(0, (1 - t) * 14), child: child),
    ),
    child: child,
  );
}

class _Message extends StatelessWidget {
  const _Message({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: ReelInk.booth,
    child: Center(
      child: _Reveal(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 40, height: 2, color: ReelInk.lamp),
            const SizedBox(height: 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(color: ReelInk.paper, fontSize: 28, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            Text(body, style: const TextStyle(color: ReelInk.dim, fontSize: 15)),
          ],
        ),
      ),
    ),
  );
}

/// Loading: a dark booth with the lamp warming up.
class ReelCurtain extends StatelessWidget {
  const ReelCurtain({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: ReelInk.booth,
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.2, end: 1),
            duration: const Duration(milliseconds: 900),
            curve: Curves.easeInOut,
            builder: (context, t, _) => Container(
              width: 64 * t,
              height: 2,
              decoration: BoxDecoration(
                color: ReelInk.lamp,
                boxShadow: [BoxShadow(color: ReelInk.lamp.withValues(alpha: 0.6 * t), blurRadius: 18)],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            label.toUpperCase(),
            style: const TextStyle(color: ReelInk.dim, fontSize: 12, letterSpacing: 3.2, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    ),
  );
}

/// The deck name for 1.5 s after a change, like a channel number.
class ReelDeckStrip extends StatelessWidget {
  const ReelDeckStrip({super.key, required this.controller});

  final ReelController controller;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String?>(
    valueListenable: controller.deckStrip,
    builder: (context, name, _) => Positioned(
      top: 36,
      right: 40,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        child: name == null
            ? const SizedBox.shrink()
            : Container(
                key: ValueKey(name),
                padding: const EdgeInsets.fromLTRB(14, 8, 16, 8),
                decoration: BoxDecoration(
                  color: const Color(0xCC0B0A09),
                  border: const Border(left: BorderSide(color: ReelInk.lamp, width: 3)),
                  borderRadius: BorderRadius.circular(2),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      (controller.deckIndex + 1).toString().padLeft(2, '0'),
                      style: const TextStyle(
                        color: ReelInk.lamp,
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      name.toUpperCase(),
                      style: const TextStyle(
                        color: ReelInk.paper,
                        fontSize: 14,
                        letterSpacing: 2,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
      ),
    ),
  );
}

/// One-line confirmations ("On the TV tonight").
class ReelToast extends StatelessWidget {
  const ReelToast({super.key, required this.controller});

  final ReelController controller;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String?>(
    valueListenable: controller.toast,
    builder: (context, text, _) => Positioned(
      top: 36,
      left: 0,
      right: 0,
      child: Center(
        child: AnimatedOpacity(
          opacity: text == null ? 0 : 1,
          duration: const Duration(milliseconds: 200),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            decoration: BoxDecoration(color: ReelInk.lamp, borderRadius: BorderRadius.circular(40)),
            child: Text(
              text ?? '',
              style: const TextStyle(color: ReelInk.booth, fontWeight: FontWeight.w800, fontSize: 14),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Fold: the deck chips along the top.
class ReelDeckChips extends StatelessWidget {
  const ReelDeckChips({super.key, required this.controller});

  final ReelController controller;

  @override
  Widget build(BuildContext context) => Positioned(
    top: MediaQuery.paddingOf(context).top + 8,
    left: 0,
    right: 0,
    height: 40,
    child: ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      children: [
        for (final (i, d) in controller.decks.indexed)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              selected: i == controller.deckIndex,
              onSelected: (_) => controller.openDeck(d.id),
              selectedColor: ReelInk.lamp,
              backgroundColor: const Color(0x660B0A09),
              labelStyle: TextStyle(
                color: i == controller.deckIndex ? ReelInk.booth : ReelInk.paper,
                fontWeight: FontWeight.w700,
              ),
              side: BorderSide.none,
              showCheckmark: false,
            ),
          ),
      ],
    ),
  );
}
