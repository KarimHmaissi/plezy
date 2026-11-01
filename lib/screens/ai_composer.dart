import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../focus/focusable_button.dart';
import '../focus/focusable_text_field.dart';
import '../i18n/strings.g.dart';
import '../media/ids.dart';
import '../media/media_item.dart';
import '../theme/fork_motion.dart';
import '../utils/platform_detector.dart';
import '../utils/provider_extensions.dart';
import '../widgets/optimized_media_image.dart';
import '../widgets/pressable.dart';

/// Projector-lamp amber: the composer's one accent.
const _amber = Color(0xFFE5A00D);
const _display = 'Bebas Neue';

/// Fork: the full-screen AI composer, the way into the AI feature, themed
/// as a cinema. It opens with a camera iris, asks in a big condensed
/// headline over a soft wall of the user's posters, and while a request
/// runs a strip of those posters races through a projector gate, then
/// slows and stops with the top pick framed. Closing never cancels a
/// request: it carries on in the background and lands as a row as before.
class AiComposer extends StatefulWidget {
  const AiComposer({
    super.key,
    required this.run,
    this.landing,
    this.followUpOf,
    this.recent = const [],
    this.posters = const [],
  });

  /// Runs a request; the film strip runs until it completes.
  final Future<void> Function(String request) run;

  /// After [run], the answer's top pick to freeze on, if there is one.
  final MediaItem? Function(String request)? landing;

  /// The request being followed up, if any.
  final String? followUpOf;

  /// The user's last asks, newest first.
  final List<String> recent;

  /// Library items for the backdrop and the film strip.
  final List<MediaItem> posters;

  static Future<void> open(
    BuildContext context, {
    required Future<void> Function(String request) run,
    MediaItem? Function(String request)? landing,
    String? followUpOf,
    List<String> recent = const [],
    List<MediaItem> posters = const [],
  }) {
    ForkMotion.success();
    return Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        transitionDuration: const Duration(milliseconds: 260),
        reverseTransitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (_, _, _) =>
            AiComposer(run: run, landing: landing, followUpOf: followUpOf, recent: recent, posters: posters),
        transitionsBuilder: (context, animation, _, child) {
          if (ForkMotion.reduceMotion(context)) return FadeTransition(opacity: animation, child: child);
          return _IrisTransition(animation: animation, child: child);
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

  /// Staggers the page in after the iris: backdrop, headline, input, chips.
  late final AnimationController _intro = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));
  late final AnimationController _drift = AnimationController(vsync: this, duration: const Duration(seconds: 90));

  /// Freeze-frame flash when the strip lands.
  late final AnimationController _flash = AnimationController(vsync: this, duration: const Duration(milliseconds: 320));

  // Film strip: its scroll position (px) advanced by a ticker.
  late final Ticker _stripTicker = createTicker(_tickStrip);
  final ValueNotifier<double> _stripPos = ValueNotifier(0);
  Duration _lastTick = Duration.zero;
  double _speed = 0;
  _Landing? _land;
  int? _pickSlot;
  MediaItem? _pick;

  Timer? _typer;
  String _placeholder = '';
  int _exampleIndex = 0;
  bool _thinking = false;
  bool _landed = false;
  int _take = 0;
  final List<Timer> _takeTimers = [];
  bool _reduceMotion = false;
  bool _started = false;

  List<String> get _examples => [
    t.aiComposer.example1,
    t.aiComposer.example2,
    t.aiComposer.example3,
    t.aiComposer.example4,
    t.aiComposer.example5,
  ];

  List<String> get _takes => [t.aiComposer.take1, t.aiComposer.take2, t.aiComposer.take3];

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
    final reduce = ForkMotion.reduceMotion(context);
    if (_started && reduce == _reduceMotion) return;
    _started = true;
    _reduceMotion = reduce;
    if (reduce) {
      _intro.value = 1;
      _drift.stop();
      _typer?.cancel();
      _placeholder = _examples.first;
    } else {
      // A beat after the iris snaps open.
      unawaited(Future.delayed(const Duration(milliseconds: 120), () => mounted ? _intro.forward() : null));
      _drift.repeat();
      _startTyping();
    }
  }

  @override
  void dispose() {
    _typer?.cancel();
    for (final timer in _takeTimers) {
      timer.cancel();
    }
    _stripTicker.dispose();
    _stripPos.dispose();
    _intro.dispose();
    _drift.dispose();
    _flash.dispose();
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

  // ---- Film strip motion ----

  static const _maxSpeed = 2400.0; // px/s: a blur of frames
  static const _accel = 6000.0;

  double _pitch = 1;

  void _tickStrip(Duration elapsed) {
    final dt = (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    final land = _land;
    if (land != null) {
      final p = ((elapsed - land.start).inMicroseconds / land.duration.inMicroseconds).clamp(0.0, 1.0);
      _stripPos.value = lerpDouble(land.from, land.to, Curves.easeOutCubic.transform(p))!;
      if (p >= 1) {
        _stripTicker.stop();
        _onLanded();
      }
      return;
    }
    _speed = math.min(_maxSpeed, _speed + _accel * dt);
    _stripPos.value += _speed * dt;
  }

  /// Slows the strip so that a frame stops in the gate. The ease-out starts
  /// at the strip's current speed, so there's no lurch.
  void _startLanding() {
    if (!_stripTicker.isActive || _speed <= 0) {
      _onLanded();
      return;
    }
    final pos = _stripPos.value;
    // An ease-out cubic starts at 3x its average speed.
    const minMs = 700.0;
    final minDistance = _speed * minMs / 1000 / 3;
    final slot = ((pos + minDistance) / _pitch).ceil();
    final to = slot * _pitch;
    final ms = (3 * (to - pos) / _speed * 1000).clamp(minMs, 1600.0);
    setState(() {
      _pickSlot = slot;
      _land = _Landing(
        from: pos,
        to: to,
        start: _lastTick,
        duration: Duration(milliseconds: ms.round()),
      );
    });
  }

  void _onLanded() {
    if (!mounted) return;
    ForkMotion.success();
    setState(() {
      _landed = true;
      _take = _takes.length; // "That's a wrap"
    });
    if (!_reduceMotion) unawaited(_flash.forward(from: 0));
    unawaited(
      Future.delayed(Duration(milliseconds: _pick != null ? 900 : 350), () {
        if (mounted) unawaited(Navigator.of(context).maybePop());
      }),
    );
  }

  Future<void> _send([String? text]) async {
    final request = (text ?? _controller.text).trim();
    if (request.isEmpty || _thinking) return;
    ForkMotion.selection();
    FocusScope.of(context).unfocus();
    setState(() {
      _thinking = true;
      _controller.text = request;
    });
    _typer?.cancel();
    _takeTimers.addAll([
      Timer(const Duration(milliseconds: 2400), () => mounted && !_landed ? setState(() => _take = 1) : null),
      Timer(const Duration(milliseconds: 6000), () => mounted && !_landed ? setState(() => _take = 2) : null),
    ]);
    if (!_reduceMotion) {
      _lastTick = Duration.zero;
      unawaited(_stripTicker.start());
    }
    var ok = false;
    try {
      await widget.run(request);
      ok = true;
    } finally {
      for (final timer in _takeTimers) {
        timer.cancel();
      }
      if (mounted) {
        final pick = ok ? widget.landing?.call(request) : null;
        if (pick != null) setState(() => _pick = pick);
        if (_reduceMotion || pick == null) {
          _stripTicker.stop();
          _onLanded();
        } else {
          _startLanding();
        }
      }
    }
  }

  FocusNode _chipNode(int i) {
    while (_chipFocus.length <= i) {
      _chipFocus.add(FocusNode(debugLabel: 'AiComposerChip${_chipFocus.length}'));
    }
    return _chipFocus[i];
  }

  Animation<double> _stage(double begin, double end) => CurvedAnimation(
    parent: _intro,
    curve: Interval(begin, end, curve: Curves.easeOutCubic),
  );

  Widget _rise(double begin, double end, Widget child) {
    final a = _stage(begin, end);
    return FadeTransition(
      opacity: a,
      child: SlideTransition(
        position: Tween(begin: const Offset(0, 0.25), end: Offset.zero).animate(a),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isTv = PlatformDetector.isTV();
    final size = MediaQuery.sizeOf(context);
    final wide = isTv || size.width >= 700;

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
              FadeTransition(
                opacity: _stage(0, 0.6),
                child: _Mosaic(items: widget.posters, drift: _drift),
              ),
              // House lights down: a heavy vignette, darkest at the edges.
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    radius: 1.1,
                    colors: [Color(0xB3000000), Color(0xEB000000), Color(0xFF000000)],
                    stops: [0, 0.65, 1],
                  ),
                ),
              ),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, a) => FadeTransition(
                  opacity: a,
                  child: ScaleTransition(scale: Tween(begin: 0.97, end: 1.0).animate(a), child: child),
                ),
                child: _thinking ? _thinkingView(size, isTv, wide) : _composeView(isTv, wide),
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

  Widget _composeView(bool isTv, bool wide) {
    final theme = Theme.of(context);
    final chips = _quickStarts;
    final hasText = _controller.text.trim().isNotEmpty;
    final headlineSize = isTv ? 104.0 : (wide ? 88.0 : 60.0);
    final inputSize = isTv ? 30.0 : (wide ? 26.0 : 21.0);
    return SafeArea(
      key: const ValueKey('compose'),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: wide ? 980 : 640),
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(horizontal: wide ? 48 : 22, vertical: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _rise(
                  0.1,
                  0.55,
                  Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(color: _amber, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        t.aiComposer.eyebrow,
                        style: TextStyle(
                          fontFamily: _display,
                          fontSize: isTv ? 24 : 18,
                          letterSpacing: 4,
                          color: _amber,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                _rise(
                  0.15,
                  0.65,
                  Text(
                    (widget.followUpOf == null ? t.aiComposer.headline : t.aiComposer.followUpHeadline).toUpperCase(),
                    style: TextStyle(
                      fontFamily: _display,
                      fontSize: headlineSize,
                      height: 0.92,
                      letterSpacing: 0.5,
                      color: Colors.white,
                    ),
                  ),
                ),
                if (widget.followUpOf != null) ...[
                  const SizedBox(height: 8),
                  _rise(
                    0.2,
                    0.7,
                    Text(
                      '“${widget.followUpOf}”',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(color: Colors.white60, fontStyle: FontStyle.italic),
                    ),
                  ),
                ],
                SizedBox(height: wide ? 36 : 28),
                // The input: big type on an amber rule, like a marquee line.
                _rise(
                  0.3,
                  0.8,
                  AnimatedBuilder(
                    animation: _fieldFocus,
                    builder: (context, child) => DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: _fieldFocus.hasFocus ? _amber : Colors.white24,
                            width: _fieldFocus.hasFocus ? 2.5 : 1.5,
                          ),
                        ),
                      ),
                      child: child,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Expanded(
                            child: TextSelectionTheme(
                              data: const TextSelectionThemeData(cursorColor: _amber),
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
                                  hintStyle: TextStyle(
                                    fontSize: inputSize,
                                    color: Colors.white38,
                                    fontWeight: FontWeight.w400,
                                  ),
                                ),
                                onSubmitted: (_) => unawaited(_send()),
                                onNavigateRight: _sendFocus.requestFocus,
                                onNavigateDown: () => _chipNode(0).requestFocus(),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          FocusableButton(
                            focusNode: _sendFocus,
                            onPressed: hasText ? () => unawaited(_send()) : null,
                            onNavigateLeft: _fieldFocus.requestFocus,
                            onNavigateDown: () => _chipNode(0).requestFocus(),
                            child: Pressable(
                              longPress: false,
                              enabled: hasText,
                              borderRadius: BorderRadius.circular(10),
                              child: _RollButton(
                                enabled: hasText,
                                onTap: () => unawaited(_send()),
                                size: inputSize * 2.3,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                SizedBox(height: wide ? 32 : 26),
                _rise(
                  0.4,
                  0.9,
                  Text(
                    t.aiComposer.quickStart,
                    style: TextStyle(
                      fontFamily: _display,
                      fontSize: isTv ? 22 : 17,
                      letterSpacing: 3,
                      color: Colors.white54,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                _rise(
                  0.45,
                  1,
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
                            borderRadius: BorderRadius.circular(6),
                            child: _Ticket(chip: chip, large: isTv, onTap: () => unawaited(_send(chip.request))),
                          ),
                        );
                      },
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

  Widget _thinkingView(Size size, bool isTv, bool wide) {
    final theme = Theme.of(context);
    final frameH = isTv ? 260.0 : (wide ? 230.0 : 170.0);
    final frameW = frameH * 2 / 3;
    _pitch = frameW + frameW * 0.12;
    final slate = _take >= _takes.length ? t.aiComposer.wrap : _takes[_take];
    final pick = _pick;
    return SafeArea(
      key: const ValueKey('thinking'),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            transitionBuilder: (child, a) => FadeTransition(
              opacity: a,
              child: SlideTransition(
                position: Tween(begin: const Offset(0, 0.4), end: Offset.zero).animate(a),
                child: child,
              ),
            ),
            child: Text(
              slate.toUpperCase(),
              key: ValueKey(slate),
              style: TextStyle(
                fontFamily: _display,
                fontSize: isTv ? 40 : 30,
                letterSpacing: 3,
                color: _landed ? _amber : Colors.white,
              ),
            ),
          ),
          SizedBox(height: isTv ? 28 : 20),
          _FilmStrip(
            items: widget.posters,
            position: _stripPos,
            frameW: frameW,
            frameH: frameH,
            pitch: _pitch,
            pickSlot: _pickSlot,
            pick: pick,
            flash: _flash,
            gateLit: _landed,
          ),
          SizedBox(height: isTv ? 28 : 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: _landed && pick != null
                  ? Text(
                      pick.displayTitle.toUpperCase(),
                      key: const ValueKey('pick'),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontFamily: _display, fontSize: isTv ? 52 : 40, color: Colors.white),
                    )
                  : Text(
                      '“${_controller.text.trim()}”',
                      key: const ValueKey('request'),
                      textAlign: TextAlign.center,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleLarge?.copyWith(color: Colors.white70, fontStyle: FontStyle.italic),
                    ),
            ),
          ),
          const SizedBox(height: 18),
          Text(t.aiComposer.keepsRunning, style: theme.textTheme.bodySmall?.copyWith(color: Colors.white38)),
        ],
      ),
    );
  }
}

class _Landing {
  const _Landing({required this.from, required this.to, required this.start, required this.duration});
  final double from;
  final double to;
  final Duration start;
  final Duration duration;
}

/// Send: an amber "roll camera" key.
class _RollButton extends StatelessWidget {
  const _RollButton({required this.enabled, required this.onTap, required this.size});
  final bool enabled;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: enabled ? _amber : const Color(0x1FFFFFFF),
        ),
        child: Icon(
          Symbols.play_arrow_rounded,
          fill: 1,
          color: enabled ? Colors.black : Colors.white38,
          size: size * 0.6,
        ),
      ),
    );
  }
}

/// A quick start, shaped like a cinema ticket stub.
class _Ticket extends StatelessWidget {
  const _Ticket({required this.chip, required this.large, required this.onTap});
  final _QuickStart chip;
  final bool large;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(6)),
      side: BorderSide(color: Color(0x2EFFFFFF)),
    );
    return Material(
      color: const Color(0x14FFFFFF),
      shape: shape,
      child: InkWell(
        customBorder: shape,
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: large ? 20 : 14),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(chip.icon, size: large ? 22 : 18, color: _amber),
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

/// A strip of 35mm film running through a projector gate: the user's
/// posters as frames, sprocket holes above and below, the gate in the
/// middle lit, the frames either side falling into the dark. Posters are
/// fetched tiny so they're soft at speed without a live blur; the picked
/// frame comes in sharp.
class _FilmStrip extends StatelessWidget {
  const _FilmStrip({
    required this.items,
    required this.position,
    required this.frameW,
    required this.frameH,
    required this.pitch,
    required this.pickSlot,
    required this.pick,
    required this.flash,
    required this.gateLit,
  });

  final List<MediaItem> items;
  final ValueListenable<double> position;
  final double frameW;
  final double frameH;
  final double pitch;
  final int? pickSlot;
  final MediaItem? pick;
  final Animation<double> flash;
  final bool gateLit;

  MediaItem? _itemAt(int slot) {
    if (slot == pickSlot && pick != null) return pick;
    if (items.isEmpty) return null;
    return items[slot % items.length];
  }

  @override
  Widget build(BuildContext context) {
    final band = frameH * 0.16;
    final height = frameH + band * 2;
    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final left = width / 2 - frameW / 2;
          return Stack(
            clipBehavior: Clip.none,
            children: [
              // The film base and its sprocket holes, scrolling with the frames.
              Positioned.fill(
                child: RepaintBoundary(child: CustomPaint(painter: _SprocketPainter(position, pitch, band))),
              ),
              Positioned(
                left: 0,
                right: 0,
                top: band,
                height: frameH,
                child: ValueListenableBuilder<double>(
                  valueListenable: position,
                  builder: (context, pos, _) {
                    final first = ((pos - left) / pitch).floor() - 1;
                    final last = ((pos + width - left) / pitch).ceil() + 1;
                    return Stack(
                      clipBehavior: Clip.none,
                      children: [
                        for (var slot = first; slot <= last; slot++)
                          Positioned(
                            key: ValueKey(slot),
                            left: left + slot * pitch - pos,
                            top: 0,
                            width: frameW,
                            height: frameH,
                            child: _Frame(item: _itemAt(slot), sharp: slot == pickSlot, number: slot),
                          ),
                      ],
                    );
                  },
                ),
              ),
              // Frames off the gate fall into the dark.
              const Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Colors.black, Color(0x99000000), Color(0x00000000), Color(0x99000000), Colors.black],
                        stops: [0, 0.3, 0.5, 0.7, 1],
                      ),
                    ),
                  ),
                ),
              ),
              // The gate: corner brackets around the centre frame.
              Positioned(
                left: left - 8,
                top: band - 8,
                width: frameW + 16,
                height: frameH + 16,
                child: IgnorePointer(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      CustomPaint(painter: _GatePainter(lit: gateLit)),
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: AnimatedBuilder(
                          animation: flash,
                          builder: (context, _) {
                            final v = flash.isAnimating ? (1 - flash.value) * 0.7 : 0.0;
                            return ColoredBox(color: Colors.white.withValues(alpha: v));
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Frame extends StatelessWidget {
  const _Frame({required this.item, required this.sharp, required this.number});
  final MediaItem? item;
  final bool sharp;
  final int number;

  @override
  Widget build(BuildContext context) {
    final item = this.item;
    final path = item?.thumbPath ?? item?.artPath;
    Widget child;
    if (item == null || path == null) {
      child = ColoredBox(
        color: const Color(0xFF15120F),
        child: Center(
          child: Text(
            '${number.abs() % 99 + 1}',
            style: const TextStyle(fontFamily: _display, fontSize: 40, color: Colors.white24),
          ),
        ),
      );
    } else {
      final client = context.tryGetMediaClientWithFallback(serverIdOrNull(item.serverId));
      child = sharp
          ? OptimizedMediaImage(client: client, imagePath: path, fit: BoxFit.cover)
          // Fetched at 40x60 and scaled up: soft, like motion blur.
          : FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: 40,
                height: 60,
                child: OptimizedMediaImage(
                  client: client,
                  imagePath: path,
                  width: 40,
                  height: 60,
                  fit: BoxFit.cover,
                  fadeInDuration: Duration.zero,
                ),
              ),
            );
    }
    return ClipRRect(borderRadius: BorderRadius.circular(3), child: child);
  }
}

/// The strip's film base: a dark band with rounded sprocket holes top and
/// bottom, scrolling with [position].
class _SprocketPainter extends CustomPainter {
  _SprocketPainter(this.position, this.pitch, this.band) : super(repaint: position);
  final ValueListenable<double> position;
  final double pitch;
  final double band;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF1C1814));
    final hole = Paint()..color = Colors.black;
    // Four holes per frame, as on 35mm.
    final step = pitch / 4;
    final holeW = step * 0.5;
    final holeH = band * 0.46;
    final shift = -(position.value % step);
    for (var x = shift; x < size.width + step; x += step) {
      for (final y in [(band - holeH) / 2, size.height - band + (band - holeH) / 2]) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTWH(x, y, holeW, holeH), Radius.circular(holeH * 0.25)),
          hole,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_SprocketPainter old) => old.pitch != pitch || old.band != band;
}

/// Projector-gate corner brackets; amber once the strip lands.
class _GatePainter extends CustomPainter {
  _GatePainter({required this.lit});
  final bool lit;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.square
      ..color = lit ? _amber : Colors.white70;
    final arm = size.shortestSide * 0.16;
    final w = size.width;
    final h = size.height;
    final path = Path()
      ..moveTo(0, arm)
      ..lineTo(0, 0)
      ..lineTo(arm, 0)
      ..moveTo(w - arm, 0)
      ..lineTo(w, 0)
      ..lineTo(w, arm)
      ..moveTo(w, h - arm)
      ..lineTo(w, h)
      ..lineTo(w - arm, h)
      ..moveTo(arm, h)
      ..lineTo(0, h)
      ..lineTo(0, h - arm);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_GatePainter old) => old.lit != lit;
}

/// Route transition: a seven-bladed camera iris snapping open over the
/// page behind, and closing again on the way out.
class _IrisTransition extends StatelessWidget {
  const _IrisTransition({required this.animation, required this.child});
  final Animation<double> animation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
    return AnimatedBuilder(
      animation: curved,
      child: child,
      builder: (context, child) {
        final p = curved.value;
        if (p >= 1) return child!;
        return Stack(
          fit: StackFit.expand,
          children: [
            ClipPath(clipper: _IrisClipper(p), child: child),
            IgnorePointer(child: CustomPaint(painter: _BladesPainter(p))),
          ],
        );
      },
    );
  }
}

const _blades = 7;

/// The aperture: a heptagon that grows and turns as the iris opens, big
/// enough at 1 to clear the corners.
Path _aperture(Size size, double p) {
  final c = size.center(Offset.zero);
  final full = size.longestSide * 0.62 / math.cos(math.pi / _blades) * 1.15;
  final r = full * p;
  final turn = (1 - p) * math.pi * 0.55;
  final path = Path();
  for (var i = 0; i < _blades; i++) {
    final a = turn + i * 2 * math.pi / _blades;
    final v = c + Offset(math.cos(a), math.sin(a)) * r;
    i == 0 ? path.moveTo(v.dx, v.dy) : path.lineTo(v.dx, v.dy);
  }
  return path..close();
}

class _IrisClipper extends CustomClipper<Path> {
  _IrisClipper(this.p);
  final double p;

  @override
  Path getClip(Size size) => _aperture(size, p);

  @override
  bool shouldReclip(_IrisClipper old) => old.p != p;
}

/// The blades: graphite around the aperture, with the seams between blades
/// running out from each corner along the next edge.
class _BladesPainter extends CustomPainter {
  _BladesPainter(this.p);
  final double p;

  @override
  void paint(Canvas canvas, Size size) {
    // Blades show while opening, fading as they clear the frame.
    final opacity = (math.min(1, p * 8) * (1 - p)).clamp(0.0, 1.0);
    if (opacity <= 0) return;
    final aperture = _aperture(size, p);
    final outside = Path.combine(PathOperation.difference, Path()..addRect(Offset.zero & size), aperture);
    canvas.drawPath(outside, Paint()..color = const Color(0xFF0E0E10).withValues(alpha: opacity));

    final metrics = aperture.computeMetrics().first;
    final seam = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = Colors.white.withValues(alpha: 0.18 * opacity);
    final edge = metrics.length / _blades;
    final reach = size.longestSide;
    for (var i = 0; i < _blades; i++) {
      final a = metrics.getTangentForOffset(i * edge)!;
      final b = metrics.getTangentForOffset(((i + 1) % _blades) * edge + 0.01)!;
      final dir = b.position - a.position;
      final len = dir.distance;
      if (len == 0) continue;
      // Each seam carries on past the corner where its blade's edge ends.
      canvas.drawLine(b.position, b.position + dir / len * reach, seam);
    }
    canvas.drawPath(
      aperture,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = _amber.withValues(alpha: 0.7 * opacity),
    );
  }

  @override
  bool shouldRepaint(_BladesPainter old) => old.p != p;
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
          opacity: 0.5,
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
