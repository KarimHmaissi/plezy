import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../focus/focusable_button.dart';
import '../focus/focusable_text_field.dart';
import '../i18n/strings.g.dart';
import '../media/ids.dart';
import '../media/media_item.dart';
import '../utils/platform_detector.dart';
import '../utils/provider_extensions.dart';
import '../widgets/optimized_media_image.dart';
import '../widgets/pressable.dart';

/// Fork: the full-screen AI composer, the way into the AI feature. A slow
/// mosaic of the user's own posters behind an accent glow, a large input
/// with example asks typing themselves in, quick-start chips, and a
/// "thinking" orb while the request runs. Closing never cancels a request:
/// it carries on in the background and lands as a row as before.
class AiComposer extends StatefulWidget {
  const AiComposer({super.key, required this.run, this.followUpOf, this.recent = const [], this.posters = const []});

  /// Runs a request; the orb shows until it completes.
  final Future<void> Function(String request) run;

  /// The request being followed up, if any.
  final String? followUpOf;

  /// The user's last asks, newest first.
  final List<String> recent;

  /// Library items for the backdrop mosaic.
  final List<MediaItem> posters;

  static Future<void> open(
    BuildContext context, {
    required Future<void> Function(String request) run,
    String? followUpOf,
    List<String> recent = const [],
    List<MediaItem> posters = const [],
  }) {
    return Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: true,
        transitionDuration: const Duration(milliseconds: 420),
        reverseTransitionDuration: const Duration(milliseconds: 260),
        pageBuilder: (_, _, _) => AiComposer(run: run, followUpOf: followUpOf, recent: recent, posters: posters),
        transitionsBuilder: (context, animation, _, child) {
          final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
          return FadeTransition(
            opacity: curved,
            child: ScaleTransition(scale: Tween(begin: 1.06, end: 1.0).animate(curved), child: child),
          );
        },
      ),
    );
  }

  @override
  State<AiComposer> createState() => _AiComposerState();
}

class _QuickStart {
  const _QuickStart(this.icon, this.label, this.request);
  final IconData icon;
  final String label;
  final String request;
}

class _AiComposerState extends State<AiComposer> with TickerProviderStateMixin {
  final _controller = TextEditingController();
  final _fieldFocus = FocusNode(debugLabel: 'AiComposerField');
  final _sendFocus = FocusNode(debugLabel: 'AiComposerSend');
  final List<FocusNode> _chipFocus = [];

  late final AnimationController _drift = AnimationController(vsync: this, duration: const Duration(seconds: 90));
  late final AnimationController _glow = AnimationController(vsync: this, duration: const Duration(seconds: 7));
  late final AnimationController _orb = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));

  Timer? _typer;
  String _placeholder = '';
  int _exampleIndex = 0;
  bool _thinking = false;
  int _statusIndex = 0;
  Timer? _statusTimer;
  bool _reduceMotion = false;

  List<String> get _examples => [
    t.aiComposer.example1,
    t.aiComposer.example2,
    t.aiComposer.example3,
    t.aiComposer.example4,
    t.aiComposer.example5,
  ];

  List<String> get _statuses => [
    t.aiComposer.status1,
    t.aiComposer.status2,
    t.aiComposer.status3,
    t.aiComposer.status4,
  ];

  List<_QuickStart> get _quickStarts => [
    _QuickStart(Symbols.nights_stay_rounded, t.aiComposer.tonight, t.aiComposer.tonightRequest),
    _QuickStart(Symbols.history_rounded, t.aiComposer.history, t.aiComposer.historyRequest),
    _QuickStart(Symbols.diamond_rounded, t.aiComposer.gems, t.aiComposer.gemsRequest),
    _QuickStart(Symbols.sentiment_very_satisfied_rounded, t.aiComposer.feelGood, t.aiComposer.feelGoodRequest),
    _QuickStart(Symbols.casino_rounded, t.aiComposer.random, t.aiComposer.randomRequest),
    for (final r in widget.recent.take(5)) _QuickStart(Symbols.schedule_rounded, r, r),
  ];

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduce = MediaQuery.disableAnimationsOf(context);
    if (reduce == _reduceMotion && (_drift.isAnimating || reduce)) return;
    _reduceMotion = reduce;
    if (reduce) {
      _drift.stop();
      _glow.stop();
      _typer?.cancel();
      _placeholder = _examples.first;
    } else {
      _drift.repeat();
      _glow.repeat(reverse: true);
      _startTyping();
    }
  }

  @override
  void dispose() {
    _typer?.cancel();
    _statusTimer?.cancel();
    _drift.dispose();
    _glow.dispose();
    _orb.dispose();
    _controller.dispose();
    _fieldFocus.dispose();
    _sendFocus.dispose();
    for (final f in _chipFocus) {
      f.dispose();
    }
    super.dispose();
  }

  /// Types an example ask into the placeholder, holds it, erases it, and
  /// moves on to the next.
  void _startTyping() {
    _typer?.cancel();
    var chars = 0;
    var holding = 0;
    var erasing = false;
    _typer = Timer.periodic(const Duration(milliseconds: 55), (_) {
      if (!mounted) return;
      final text = _examples[_exampleIndex % _examples.length];
      if (!erasing) {
        if (chars < text.length) {
          chars++;
        } else if (++holding > 40) {
          erasing = true;
          holding = 0;
        }
      } else if (chars > 0) {
        chars = math.max(0, chars - 2);
      } else {
        erasing = false;
        _exampleIndex++;
      }
      setState(() => _placeholder = text.substring(0, math.min(chars, text.length)));
    });
  }

  Future<void> _send([String? text]) async {
    final request = (text ?? _controller.text).trim();
    if (request.isEmpty || _thinking) return;
    unawaited(HapticFeedback.lightImpact());
    FocusScope.of(context).unfocus();
    setState(() {
      _thinking = true;
      _controller.text = request;
    });
    _typer?.cancel();
    if (!_reduceMotion) _orb.repeat();
    _statusTimer = Timer.periodic(const Duration(milliseconds: 2200), (_) {
      if (mounted) setState(() => _statusIndex++);
    });
    try {
      await widget.run(request);
    } finally {
      _statusTimer?.cancel();
      if (mounted) unawaited(Navigator.of(context).maybePop());
    }
  }

  FocusNode _chipNode(int i) {
    while (_chipFocus.length <= i) {
      _chipFocus.add(FocusNode(debugLabel: 'AiComposerChip${_chipFocus.length}'));
    }
    return _chipFocus[i];
  }

  @override
  Widget build(BuildContext context) {
    final isTv = PlatformDetector.isTV();
    final size = MediaQuery.sizeOf(context);
    final wide = isTv || size.width >= 700;
    final accent = Theme.of(context).colorScheme.primary;
    final headlineSize = isTv ? 44.0 : (wide ? 36.0 : 28.0);
    final inputSize = isTv ? 28.0 : (wide ? 24.0 : 20.0);

    return PopScope(
      child: Scaffold(
        backgroundColor: Colors.black,
        resizeToAvoidBottomInset: true,
        body: GestureDetector(
          onVerticalDragEnd: (d) {
            if ((d.primaryVelocity ?? 0) > 700) Navigator.of(context).maybePop();
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              _Mosaic(items: widget.posters, drift: _drift),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xCC05060A), Color(0xE605060A), Color(0xFA05060A)],
                  ),
                ),
              ),
              _Aurora(animation: _glow, color: accent),
              SafeArea(
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: wide ? 980 : 640),
                    child: SingleChildScrollView(
                      padding: EdgeInsets.symmetric(horizontal: wide ? 48 : 22, vertical: 24),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 380),
                        switchInCurve: Curves.easeOutCubic,
                        child: _thinking
                            ? _thinkingView(accent, headlineSize)
                            : _composeView(accent, headlineSize, inputSize, isTv),
                      ),
                    ),
                  ),
                ),
              ),
              SafeArea(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: IconButton(
                      tooltip: t.common.close,
                      icon: const Icon(Symbols.close_rounded, color: Colors.white70),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _composeView(Color accent, double headlineSize, double inputSize, bool isTv) {
    final theme = Theme.of(context);
    final chips = _quickStarts;
    final hasText = _controller.text.trim().isNotEmpty;
    return Column(
      key: const ValueKey('compose'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(Symbols.auto_awesome_rounded, color: accent, size: headlineSize * 0.6, fill: 1),
            const SizedBox(width: 10),
            Text(
              t.aiComposer.eyebrow,
              style: theme.textTheme.labelLarge?.copyWith(color: accent, letterSpacing: 2, fontWeight: FontWeight.w700),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Text(
          widget.followUpOf == null ? t.aiComposer.headline : t.aiComposer.followUpHeadline,
          style: theme.textTheme.displaySmall?.copyWith(
            fontSize: headlineSize,
            fontWeight: FontWeight.w800,
            height: 1.1,
            color: Colors.white,
            letterSpacing: -0.5,
          ),
        ),
        if (widget.followUpOf != null) ...[
          const SizedBox(height: 8),
          Text(
            '“${widget.followUpOf}”',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(color: Colors.white60, fontStyle: FontStyle.italic),
          ),
        ],
        const SizedBox(height: 28),
        // The input: a glassy pill lit by the accent glow.
        AnimatedBuilder(
          animation: _glow,
          builder: (context, child) => DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(28),
              color: const Color(0x1FFFFFFF),
              border: Border.all(color: accent.withValues(alpha: 0.35 + 0.25 * _glow.value), width: 1.5),
              boxShadow: [
                BoxShadow(color: accent.withValues(alpha: 0.18 + 0.14 * _glow.value), blurRadius: 40, spreadRadius: 2),
              ],
            ),
            child: child,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 10, 10, 10),
            child: Row(
              children: [
                Expanded(
                  child: FocusableTextField(
                    controller: _controller,
                    focusNode: _fieldFocus,
                    autofocus: true,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    textCapitalization: TextCapitalization.sentences,
                    style: TextStyle(
                      fontSize: inputSize,
                      color: Colors.white,
                      fontWeight: FontWeight.w500,
                      height: 1.3,
                    ),
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      filled: false,
                      isCollapsed: true,
                      hintText: _placeholder.isEmpty ? ' ' : '$_placeholder▍',
                      hintStyle: TextStyle(fontSize: inputSize, color: Colors.white38, fontWeight: FontWeight.w400),
                    ),
                    onSubmitted: (_) => unawaited(_send()),
                    onNavigateRight: _sendFocus.requestFocus,
                    onNavigateDown: () => _chipNode(0).requestFocus(),
                  ),
                ),
                const SizedBox(width: 8),
                FocusableButton(
                  focusNode: _sendFocus,
                  onPressed: hasText ? () => unawaited(_send()) : null,
                  onNavigateLeft: _fieldFocus.requestFocus,
                  onNavigateDown: () => _chipNode(0).requestFocus(),
                  child: _SendButton(
                    accent: accent,
                    enabled: hasText,
                    onTap: () => unawaited(_send()),
                    size: inputSize * 2.4,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 28),
        Text(
          t.aiComposer.quickStart,
          style: theme.textTheme.labelLarge?.copyWith(color: Colors.white54, letterSpacing: 1.2),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: isTv ? 56 : 46,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            itemCount: chips.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, i) {
              final chip = chips[i];
              return FocusableButton(
                focusNode: _chipNode(i),
                onPressed: () => unawaited(_send(chip.request)),
                onNavigateLeft: i > 0 ? () => _chipNode(i - 1).requestFocus() : null,
                onNavigateRight: i < chips.length - 1 ? () => _chipNode(i + 1).requestFocus() : null,
                onNavigateUp: _fieldFocus.requestFocus,
                child: Pressable(
                  longPress: false,
                  borderRadius: BorderRadius.circular(40),
                  child: _Chip(chip: chip, accent: accent, large: isTv, onTap: () => unawaited(_send(chip.request))),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _thinkingView(Color accent, double headlineSize) {
    final theme = Theme.of(context);
    final status = _statuses[_statusIndex % _statuses.length];
    return Column(
      key: const ValueKey('thinking'),
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox.square(
          dimension: 180,
          child: _Orb(animation: _orb, color: accent),
        ),
        const SizedBox(height: 28),
        Text(
          '“${_controller.text.trim()}”',
          textAlign: TextAlign.center,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.headlineSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 14),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 400),
          child: Text(
            status,
            key: ValueKey(status),
            style: theme.textTheme.titleMedium?.copyWith(color: accent.withValues(alpha: 0.9)),
          ),
        ),
        const SizedBox(height: 24),
        Text(t.aiComposer.keepsRunning, style: theme.textTheme.bodySmall?.copyWith(color: Colors.white38)),
      ],
    );
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({required this.accent, required this.enabled, required this.onTap, required this.size});
  final Color accent;
  final bool enabled;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: enabled
              ? LinearGradient(colors: [accent, Color.lerp(accent, Colors.white, 0.35)!])
              : const LinearGradient(colors: [Color(0x33FFFFFF), Color(0x22FFFFFF)]),
          boxShadow: enabled ? [BoxShadow(color: accent.withValues(alpha: 0.55), blurRadius: 24)] : const [],
        ),
        child: Icon(Symbols.arrow_upward_rounded, color: enabled ? Colors.black : Colors.white38, size: size * 0.5),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.chip, required this.accent, required this.large, required this.onTap});
  final _QuickStart chip;
  final Color accent;
  final bool large;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0x1AFFFFFF),
      shape: StadiumBorder(side: BorderSide(color: Colors.white.withValues(alpha: 0.14))),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: large ? 22 : 16),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(chip.icon, size: large ? 22 : 18, color: accent),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 260),
                child: Text(
                  chip.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.white, fontSize: large ? 18 : 15, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A slowly drifting wall of the user's posters. Each tile is fetched tiny
/// and drawn large with smooth filtering, which blurs it for free: no live
/// blur filter, so it stays cheap on the Shield.
class _Mosaic extends StatelessWidget {
  const _Mosaic({required this.items, required this.drift});
  final List<MediaItem> items;
  final Animation<double> drift;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    const tileW = 150.0;
    const tileH = 225.0;
    final size = MediaQuery.sizeOf(context);
    final cols = (size.width / tileW).ceil() + 2;
    final rows = (size.height / tileH).ceil() + 2;
    return ClipRect(
      child: AnimatedBuilder(
        animation: drift,
        builder: (context, child) {
          final t = drift.value * 2 * math.pi;
          return Transform.translate(
            offset: Offset(-tileW + math.sin(t) * tileW * 0.8, -tileH + math.cos(t) * tileH * 0.4),
            child: child,
          );
        },
        child: Opacity(
          opacity: 0.55,
          child: OverflowBox(
            alignment: Alignment.topLeft,
            maxWidth: cols * tileW,
            maxHeight: rows * tileH,
            child: Wrap(
              children: [
                for (var i = 0; i < cols * rows; i++)
                  SizedBox(
                    width: tileW,
                    height: tileH,
                    child: _BlurTile(item: items[i % items.length]),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BlurTile extends StatelessWidget {
  const _BlurTile({required this.item});
  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    final path = item.thumbPath ?? item.artPath;
    if (path == null) return const SizedBox.shrink();
    // Fetched at 24x36 and scaled up: soft, like a heavy blur.
    return FittedBox(
      fit: BoxFit.cover,
      child: SizedBox(
        width: 24,
        height: 36,
        child: OptimizedMediaImage(
          client: context.tryGetMediaClientWithFallback(serverIdOrNull(item.serverId)),
          imagePath: path,
          width: 24,
          height: 36,
          fit: BoxFit.cover,
          fadeInDuration: const Duration(milliseconds: 600),
        ),
      ),
    );
  }
}

/// Two soft accent blobs drifting behind the input.
class _Aurora extends StatelessWidget {
  const _Aurora({required this.animation, required this.color});
  final Animation<double> animation;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: animation,
        builder: (context, _) {
          final v = Curves.easeInOut.transform(animation.value);
          return Stack(
            children: [
              Align(
                alignment: Alignment(-0.6 + 0.5 * v, -0.2 + 0.2 * v),
                child: _blob(color.withValues(alpha: 0.30), 520),
              ),
              Align(
                alignment: Alignment(0.7 - 0.4 * v, 0.4 - 0.3 * v),
                child: _blob(Color.lerp(color, const Color(0xFF7C4DFF), 0.6)!.withValues(alpha: 0.22), 460),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _blob(Color c, double size) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      gradient: RadialGradient(colors: [c, c.withValues(alpha: 0)]),
    ),
  );
}

/// The "thinking" orb: a breathing core with rings rippling out.
class _Orb extends StatelessWidget {
  const _Orb({required this.animation, required this.color});
  final Animation<double> animation;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) => CustomPaint(painter: _OrbPainter(animation.value, color)),
    );
  }
}

class _OrbPainter extends CustomPainter {
  _OrbPainter(this.t, this.color);
  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    for (var i = 0; i < 3; i++) {
      final p = (t + i / 3) % 1;
      canvas.drawCircle(
        c,
        r * (0.35 + 0.65 * p),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = color.withValues(alpha: (1 - p) * 0.5),
      );
    }
    final breath = 0.5 + 0.5 * math.sin(t * 2 * math.pi);
    canvas.drawCircle(
      c,
      r * (0.30 + 0.05 * breath),
      Paint()
        ..shader = RadialGradient(
          colors: [Colors.white, color, color.withValues(alpha: 0)],
          stops: const [0, 0.45, 1],
        ).createShader(Rect.fromCircle(center: c, radius: r * 0.4)),
    );
  }

  @override
  bool shouldRepaint(_OrbPainter old) => old.t != t || old.color != color;
}
