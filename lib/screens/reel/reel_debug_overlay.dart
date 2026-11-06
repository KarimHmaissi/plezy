import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../mpv/mpv.dart';
import '../../services/device_performance.dart';
import '../../services/reel/reel_perf.dart';
import '../../theme/fork_spacing.dart';
import '../../utils/layout_constants.dart';
import '../../widgets/fork_motion_widgets.dart';
import '../../widgets/stat_chip.dart';
import '../../widgets/video_controls/widgets/performance_overlay/performance_overlay.dart';

/// The Reel's debug overlay (plan V2-07): the last and median time from a
/// key press or swipe to the first frame, split into resolve / open /
/// decoder / render, the preload hit rate, live decoders, memory gauges and
/// frames over budget. Shown only while the hidden developer setting is on;
/// it never takes focus or touches, so the Reel behaves the same under it.
/// On the TV the player's own performance card sits beside it, on the clip
/// core.
///
/// Developer metrics, so the labels are short English abbreviations rather
/// than translated strings (the same as the player's stats card values).
class ReelDebugOverlay extends StatefulWidget {
  const ReelDebugOverlay({super.key, required this.perf, required this.tv, this.player});

  final ReelPerf perf;
  final bool tv;

  /// TV: the clip core's player, for [PlayerPerformanceOverlay].
  final Player? player;

  @override
  State<ReelDebugOverlay> createState() => _ReelDebugOverlayState();
}

class _ReelDebugOverlayState extends State<ReelDebugOverlay> {
  /// RSS, the image cache and the frame counts move without a card change.
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    final inset = widget.tv
        ? EdgeInsets.all(24 * TvLayoutConstants.scaleOf(context))
        : EdgeInsets.fromLTRB(ForkSpacing.of(context).edgeInset, kToolbarHeight + 8, 0, 0);
    return IgnorePointer(
      child: ExcludeFocus(
        child: SafeArea(
          child: Padding(
            padding: inset,
            child: Stack(
              children: [
                if (widget.tv && player != null)
                  Align(
                    alignment: Alignment.topLeft,
                    child: PlayerPerformanceOverlay(key: ObjectKey(player), player: player, active: true),
                  ),
                Align(
                  alignment: widget.tv ? Alignment.topRight : Alignment.topLeft,
                  child: ForkEntrance(
                    child: ListenableBuilder(
                      listenable: widget.perf,
                      builder: (context, _) => ReelPerfChips(perf: widget.perf, tv: widget.tv),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The overlay's figures as a column of [StatChip]s.
class ReelPerfChips extends StatelessWidget {
  const ReelPerfChips({super.key, required this.perf, required this.tv});

  final ReelPerf perf;
  final bool tv;

  static String _ms(int? v) => v == null ? '–' : '$v';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fill = scheme.surfaceContainerHigh.withValues(alpha: 0.88);
    final last = perf.last;
    final trigger = last?.trigger;
    int? p50(int? Function(ReelPerfSample s) pick) => trigger == null ? null : perf.p50(pick, trigger: trigger);
    final hits = perf.preloadHits;
    final p95 = perf.frameP95;
    final budgetMs = perf.frameBudget.inMicroseconds / 1000;
    final rss = ReelPerf.rssMb();
    final img = ReelPerf.imageMb();
    final decoders = perf.liveDecoders?.call();
    final input = trigger?.name ?? (tv ? 'key' : 'swipe');

    Widget chip(IconData icon, String label) =>
        StatChip(icon: icon, iconColor: scheme.primary, label: label, backgroundColor: fill);

    final chips = [
      chip(Symbols.timer_rounded, '$input → frame ${_ms(last?.totalMs)} ms · p50 ${_ms(p50((s) => s.totalMs))}'),
      chip(Symbols.hourglass_rounded, 'resolve ${_ms(last?.resolveMs)} · p50 ${_ms(p50((s) => s.resolveMs))}'),
      chip(Symbols.hourglass_rounded, 'open ${_ms(last?.openMs)} · p50 ${_ms(p50((s) => s.openMs))}'),
      if (tv) chip(Symbols.hourglass_rounded, 'decoder ${_ms(last?.decoderMs)} · p50 ${_ms(p50((s) => s.decoderMs))}'),
      chip(Symbols.hourglass_rounded, 'render ${_ms(last?.renderMs)} · p50 ${_ms(p50((s) => s.renderMs))}'),
      chip(
        Symbols.bolt_rounded,
        hits == null ? 'preload –' : 'preload ${(hits.hits * 100 / hits.of).round()}% (${hits.hits}/${hits.of})',
      ),
      chip(Symbols.developer_board_rounded, 'decoders ${decoders ?? '–'}'),
      chip(Symbols.memory_rounded, 'RSS ${rss == null ? '–' : '$rss MB'}'),
      chip(
        Symbols.image_rounded,
        'images ${img == null ? '–' : '${img.toStringAsFixed(1)} MB'} · '
        'budget ×${DevicePerformance.displayBudgetFactor().toStringAsFixed(2)}',
      ),
      chip(
        Symbols.speed_rounded,
        'frames over ${perf.framesOver}/${perf.frames} · p95 ${p95 == null ? '–' : p95.toStringAsFixed(1)} '
        '(${budgetMs.toStringAsFixed(1)} ms)',
      ),
      chip(Symbols.layers_rounded, 'dropped ${perf.framesDropped}'),
    ];
    return MediaQuery.withNoTextScaling(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: tv ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        spacing: 6,
        children: chips,
      ),
    );
  }
}
