import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../focus/focusable_button.dart';
import '../focus/focusable_text_field.dart';
import '../i18n/strings.g.dart';
import '../media/ids.dart';
import '../media/media_item.dart';
import '../theme/fork_motion.dart';
import '../theme/fork_spacing.dart';
import '../theme/mono_tokens.dart';
import '../utils/platform_detector.dart';
import '../utils/provider_extensions.dart';
import '../widgets/focusable_filter_chip.dart';
import '../widgets/optimized_media_image.dart';
import '../widgets/pressable.dart';

/// Fork: the full-screen AI composer, the way into the AI feature. Its
/// motion is cinema (see docs/fork/STYLE-GUIDE.md); its colours and type
/// come from the theme. It rises in calmly (ForkMotion.riseTransition), asks in a big
/// headline over a soft wall of the user's posters, and while a request
/// runs a strip of those posters races through a projector gate, then
/// slows and stops with the top pick framed. Closing never cancels a
/// request: it carries on in the background and lands as a row as before.
/// How a composer request went: the answer's top pick to freeze on, or
/// why it failed.
class AiComposerOutcome {
  const AiComposerOutcome({this.pick, this.error, this.text});
  final MediaItem? pick;
  final String? error;

  /// A written answer (Ask about this): shown as a card instead of closing.
  final String? text;
}

/// A quick start for [AiComposer.chips]: what it says and what it asks.
typedef AiComposerChip = ({IconData icon, String label, String request});

class AiComposer extends StatefulWidget {
  const AiComposer({
    super.key,
    required this.run,
    this.followUpOf,
    this.recent = const [],
    this.posters = const [],
    this.about,
    this.chips,
    this.autoRequest,
    this.notesTitle,
  });

  /// Sent as soon as the composer opens (Previously on), skipping the input.
  final String? autoRequest;

  /// The answer card's heading in place of "Programme notes".
  final String? notesTitle;

  /// The title being asked about (Ask about this), shown as a chip.
  final String? about;

  /// Quick starts in place of the usual ones.
  final List<AiComposerChip>? chips;

  /// Runs a request; the film strip runs until it completes.
  final Future<AiComposerOutcome> Function(String request) run;

  /// The request being followed up, if any.
  final String? followUpOf;

  /// The user's last asks, newest first.
  final List<String> recent;

  /// Library items for the backdrop and the film strip.
  final List<MediaItem> posters;

  static Future<void> open(
    BuildContext context, {
    required Future<AiComposerOutcome> Function(String request) run,
    String? followUpOf,
    List<String> recent = const [],
    List<MediaItem> posters = const [],
    String? about,
    List<AiComposerChip>? chips,
    String? autoRequest,
    String? notesTitle,

    /// Where the Ask button is, in global coordinates (unused since the
    /// iris was replaced by a plain rise; kept for callers).
    Rect? origin,
  }) {
    ForkMotion.success();
    return Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        transitionDuration: ForkMotion.sheetIn,
        reverseTransitionDuration: ForkMotion.sheetOut,
        pageBuilder: (_, _, _) => AiComposer(
          run: run,
          followUpOf: followUpOf,
          recent: recent,
          posters: posters,
          about: about,
          chips: chips,
          autoRequest: autoRequest,
          notesTitle: notesTitle,
        ),
        transitionsBuilder: (context, animation, _, child) {
          if (ForkMotion.reduceMotion(context)) return FadeTransition(opacity: animation, child: child);
          return ForkMotion.riseTransition(animation, child);
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

class _AiComposerState extends State<AiComposer> with TickerProviderStateMixin, WidgetsBindingObserver {
  final _controller = TextEditingController();
  final _fieldFocus = FocusNode(debugLabel: 'AiComposerField');
  final _sendFocus = FocusNode(debugLabel: 'AiComposerSend');
  final List<FocusNode> _chipFocus = [];

  /// Staggers the page in with the route's rise: backdrop, headline, input,
  /// chips.
  late final AnimationController _intro = AnimationController(vsync: this, duration: const Duration(milliseconds: 450));
  late final AnimationController _drift = AnimationController(vsync: this, duration: const Duration(seconds: 90));

  /// Freeze-frame flash when the strip lands.
  /// The clapper snapping shut on send and on each new take.
  late final AnimationController _clap = AnimationController(vsync: this, duration: const Duration(milliseconds: 170));

  /// The strip shuddering when the film jams (a failed request).
  late final AnimationController _judder = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );
  final _retryFocus = FocusNode(debugLabel: 'AiComposerRetry');
  final _browseFocus = FocusNode(debugLabel: 'AiComposerBrowse');
  final _editFocus = FocusNode(debugLabel: 'AiComposerEdit');

  late final AnimationController _flash = AnimationController(vsync: this, duration: const Duration(milliseconds: 320));

  // Film strip: its scroll position (px) advanced by a ticker.
  late final Ticker _stripTicker = createTicker(_tickStrip);
  final ValueNotifier<double> _stripPos = ValueNotifier(0);
  Duration _lastTick = Duration.zero;
  double _speed = 0;
  _Landing? _land;
  int? _pickSlot;
  MediaItem? _pick;

  /// The written answer once it's in (Ask about this).
  String? _answer;
  bool _showAnswer = false;
  final _doneFocus = FocusNode(debugLabel: 'AiComposerDone');
  final _askAnotherFocus = FocusNode(debugLabel: 'AiComposerAskAnother');

  Timer? _typer;
  String _placeholder = '';
  int _exampleIndex = 0;
  bool _thinking = false;
  bool _landed = false;
  String? _jam;
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
    if (widget.chips case final chips?) ...[
      for (final c in chips) _QuickStart(c.icon, c.label, c.request),
    ] else ...[
      _QuickStart(Symbols.nights_stay_rounded, t.aiComposer.tonight, t.aiComposer.tonightRequest),
      _QuickStart(Symbols.history_rounded, t.aiComposer.history, t.aiComposer.historyRequest),
      _QuickStart(Symbols.diamond_rounded, t.aiComposer.gems, t.aiComposer.gemsRequest),
      _QuickStart(Symbols.sentiment_very_satisfied_rounded, t.aiComposer.feelGood, t.aiComposer.feelGoodRequest),
      _QuickStart(Symbols.casino_rounded, t.aiComposer.random, t.aiComposer.randomRequest),
      for (final r in widget.recent.take(5)) _QuickStart(Symbols.schedule_rounded, r, r),
    ],
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.addListener(() => setState(() {}));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduce = ForkMotion.reduceMotion(context);
    if (_started && reduce == _reduceMotion) return;
    if (!_started && widget.autoRequest != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_send(widget.autoRequest));
      });
    }
    if (!_started && widget.autoRequest == null) _focusFieldWhenSettled();
    _started = true;
    _reduceMotion = reduce;
    if (reduce) {
      _intro.value = 1;
      _drift.stop();
      _typer?.cancel();
      _placeholder = _examples.first;
    } else {
      _intro.forward();
      _drift.repeat();
      _startTyping();
    }
  }

  /// Focus the input (and so open the keyboard) only once the route has
  /// finished rising: the keyboard resizing the page mid-transition is what
  /// made opening look like a lurch.
  void _focusFieldWhenSettled() {
    void focus() {
      if (mounted && _fieldFocus.canRequestFocus && !_fieldFocus.hasFocus) _fieldFocus.requestFocus();
    }

    final animation = ModalRoute.of(context)?.animation;
    if (animation == null || animation.isCompleted) {
      WidgetsBinding.instance.addPostFrameCallback((_) => focus());
      return;
    }
    late final AnimationStatusListener listener;
    listener = (status) {
      if (status.isCompleted) {
        animation.removeStatusListener(listener);
        focus();
      } else if (status.isDismissed) {
        animation.removeStatusListener(listener);
      }
    };
    animation.addStatusListener(listener);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Put the keyboard away before the app goes to the background, so the
    // window doesn't come back with the keyboard's inset still applied.
    // Only on a real background: Samsung reports inactive while the IME
    // itself opens.
    if (state == AppLifecycleState.paused) _dropKeyboard();
  }

  void _dropKeyboard() {
    if (_fieldFocus.hasFocus) _fieldFocus.unfocus();
    unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _typer?.cancel();
    for (final timer in _takeTimers) {
      timer.cancel();
    }
    _stripTicker.dispose();
    _stripPos.dispose();
    _intro.dispose();
    _drift.dispose();
    _flash.dispose();
    _clap.dispose();
    _judder.dispose();
    _retryFocus.dispose();
    _doneFocus.dispose();
    _askAnotherFocus.dispose();
    _browseFocus.dispose();
    _editFocus.dispose();
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
    if (widget.about != null) {
      // Asking about one title: the example asks don't fit.
      setState(() => _placeholder = t.aiComposer.aboutHint);
      return;
    }
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
    if (_answer != null) {
      // The answer card follows the freeze-frame and stays until Done.
      unawaited(
        Future.delayed(Duration(milliseconds: _pick != null ? 800 : 250), () {
          if (!mounted) return;
          setState(() => _showAnswer = true);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _doneFocus.canRequestFocus) _doneFocus.requestFocus();
          });
        }),
      );
      return;
    }
    unawaited(
      Future.delayed(Duration(milliseconds: _pick != null ? 900 : 350), () {
        if (mounted) unawaited(Navigator.of(context).maybePop());
      }),
    );
  }

  Future<void> _send([String? text]) async {
    final request = (text ?? _controller.text).trim();
    if (request.isEmpty || _thinking) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _thinking = true;
      _controller.text = request;
    });
    _typer?.cancel();
    await _roll(request);
  }

  /// Runs [request] with the strip rolling, then lands it or jams it.
  Future<void> _roll(String request) async {
    setState(() {
      _jam = null;
      _landed = false;
      _take = 0;
      _pick = null;
      _pickSlot = null;
      _land = null;
    });
    _snapClapper(haptic: true);
    for (final timer in _takeTimers) {
      timer.cancel();
    }
    _takeTimers
      ..clear()
      ..addAll([
        Timer(const Duration(milliseconds: 2400), () => _nextTake(1)),
        Timer(const Duration(milliseconds: 6000), () => _nextTake(2)),
      ]);
    if (!_reduceMotion) {
      _speed = 0;
      _lastTick = Duration.zero;
      if (!_stripTicker.isActive) unawaited(_stripTicker.start());
    }
    AiComposerOutcome outcome;
    try {
      outcome = await widget.run(request);
    } catch (e) {
      outcome = AiComposerOutcome(error: '$e');
    }
    for (final timer in _takeTimers) {
      timer.cancel();
    }
    if (!mounted) return;
    final error = outcome.error;
    if (error != null) {
      _jamStrip(error);
      return;
    }
    final text = outcome.text?.trim();
    _answer = text == null || text.isEmpty ? null : text;
    final pick = outcome.pick;
    if (pick != null) setState(() => _pick = pick);
    if (_reduceMotion || pick == null) {
      _stripTicker.stop();
      _onLanded();
    } else {
      _startLanding();
    }
  }

  void _nextTake(int take) {
    if (!mounted || _landed || _jam != null) return;
    setState(() => _take = take);
    _snapClapper(haptic: false);
  }

  void _snapClapper({required bool haptic}) {
    if (_reduceMotion) {
      _clap.value = 1;
      return;
    }
    unawaited(
      _clap.forward(from: 0).then((_) {
        if (haptic) ForkMotion.selection();
      }),
    );
  }

  /// A failed request: the strip stops dead and shudders, the gate goes
  /// red, and Retry takes focus.
  void _jamStrip(String error) {
    _stripTicker.stop();
    _speed = 0;
    ForkMotion.error();
    setState(() => _jam = error);
    if (!_reduceMotion) unawaited(_judder.forward(from: 0));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _retryFocus.canRequestFocus) _retryFocus.requestFocus();
    });
  }

  /// Closes the composer like ✕; the request carries on and lands in the
  /// AI tab.
  void _continueBrowsing() {
    ForkMotion.selection();
    unawaited(Navigator.of(context).maybePop());
  }

  void _closeAnswer() {
    ForkMotion.selection();
    unawaited(Navigator.of(context).maybePop());
  }

  /// From the answer card back to the input, for another question.
  void _askAnother() {
    ForkMotion.selection();
    _controller.clear();
    setState(() {
      _showAnswer = false;
      _thinking = false;
      _landed = false;
      _answer = null;
      _pick = null;
      _pickSlot = null;
      _land = null;
      _take = 0;
    });
    _startTyping();
    _fieldFocus.requestFocus();
  }

  void _backToEdit() {
    setState(() {
      _thinking = false;
      _jam = null;
    });
    if (!_reduceMotion) _startTyping();
    _fieldFocus.requestFocus();
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
      // Keyed so that dropping a part on short screens (the keyboard
      // opening) doesn't rebuild the parts after it, the input among them.
      key: ValueKey<double>(begin),
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
    final tk = tokens(context);

    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _dropKeyboard();
      },
      child: Scaffold(
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
              // House lights down: the page colour as a heavy vignette,
              // strongest at the edges.
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    radius: 1.1,
                    colors: [tk.bg.withValues(alpha: 0.7), tk.bg.withValues(alpha: 0.92), tk.bg],
                    stops: const [0, 0.65, 1],
                  ),
                ),
              ),
              // And stronger still behind the content at the bottom.
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [tk.bg.withValues(alpha: 0), tk.bg.withValues(alpha: 0.55), tk.bg.withValues(alpha: 0.9)],
                    stops: const [0, 0.45, 1],
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
                child: _showAnswer
                    ? _answerView(isTv, wide)
                    : (_thinking ? _thinkingView(size, isTv, wide) : _composeView(isTv, wide)),
              ),
              SafeArea(
                child: Align(
                  alignment: Alignment.topRight,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: IconButton(
                      constraints: const BoxConstraints.tightFor(width: 48, height: 48),
                      tooltip: t.common.close,
                      icon: Icon(Symbols.close_rounded, color: tk.textMuted),
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

  /// Left/right gutter: the app's touch rhythm, TV's overscan-safe inset.
  double _gutter(bool isTv) => isTv ? 48 : ForkSpacing.of(context).edgeInset;

  /// A section title, as `HubSection` styles a row's title.
  TextStyle? _sectionTitle(bool isTv, {Color? color}) => Theme.of(context).textTheme.titleLarge?.copyWith(
    fontSize: isTv ? 26 : ForkSpacing.of(context).titleSize,
    fontWeight: isTv ? FontWeight.w700 : FontWeight.w600,
    color: color,
  );

  Widget _composeView(bool isTv, bool wide) {
    return SafeArea(
      key: const ValueKey('compose'),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // The Fold's cover screen with the keyboard up leaves ~400dp:
          // there the page anchors above the keyboard and slims down.
          final h = constraints.maxHeight;
          final short = !isTv && h < 620;
          final tiny = !isTv && h < 470;
          final gutter = _gutter(isTv);
          return Align(
            alignment: short ? Alignment.bottomCenter : Alignment.center,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: wide ? 980 : 640),
              child: SingleChildScrollView(
                reverse: short,
                // Clear of the close button above.
                padding: EdgeInsets.fromLTRB(gutter, 52, gutter, short ? 12 : 24),
                child: _composeColumn(isTv, wide, short, tiny),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _composeColumn(bool isTv, bool wide, bool short, bool tiny) {
    final theme = Theme.of(context);
    final tk = tokens(context);
    final chips = _quickStarts;
    final hasText = _controller.text.trim().isNotEmpty;
    final headlineStyle =
        (tiny
                ? theme.textTheme.headlineSmall
                : (short
                      ? theme.textTheme.headlineMedium
                      : (wide ? theme.textTheme.displaySmall : theme.textTheme.headlineMedium)))
            ?.copyWith(fontWeight: FontWeight.w700, color: tk.text, height: 1.1);
    final inputSize = isTv ? 28.0 : (tiny ? 18.0 : (wide ? 24.0 : 20.0));
    final headline = widget.about != null
        ? t.aiComposer.aboutHeadline
        : (widget.followUpOf == null ? t.aiComposer.headline : t.aiComposer.followUpHeadline);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!tiny)
          _rise(
            0,
            0.3,
            Row(
              children: [
                SizedBox.square(
                  dimension: isTv ? 44 : 34,
                  child: AnimatedBuilder(
                    animation: _intro,
                    builder: (context, _) => CustomPaint(painter: _MarkPainter(_intro.value, tk.accent)),
                  ),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    widget.about != null ? t.aiComposer.aboutEyebrow : t.aiComposer.eyebrow,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: (isTv ? theme.textTheme.titleLarge : theme.textTheme.titleMedium)?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: tk.textMuted,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (!tiny) const SizedBox(height: 6),
        _rise(
          0.15,
          0.65,
          short
              // One line on short screens, shrunk to fit if need be.
              ? FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(headline, maxLines: 1, style: headlineStyle),
                )
              : Text(headline, style: headlineStyle),
        ),
        if (widget.about case final about?) ...[
          SizedBox(height: tiny ? 6 : 12),
          _rise(0.2, 0.7, _AboutChip(title: about, large: isTv)),
        ] else if (widget.followUpOf != null && !tiny) ...[
          const SizedBox(height: 8),
          _rise(
            0.2,
            0.7,
            Text(
              '“${widget.followUpOf}”',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium?.copyWith(color: tk.textMuted, fontStyle: FontStyle.italic),
            ),
          ),
        ],
        SizedBox(height: tiny ? 14 : (short ? 20 : (wide ? 36 : 28))),
        // The input: big type on a rule that lights up in the accent.
        _rise(
          0.3,
          0.8,
          AnimatedBuilder(
            animation: _fieldFocus,
            builder: (context, child) => DecoratedBox(
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: _fieldFocus.hasFocus ? tk.accent : tk.outline,
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
                      data: TextSelectionThemeData(cursorColor: tk.accent),
                      child: FocusableTextField(
                        controller: _controller,
                        focusNode: _fieldFocus,
                        // Focused once the route settles (_focusFieldWhenSettled).
                        minLines: 1,
                        maxLines: 4,
                        textInputAction: TextInputAction.send,
                        textCapitalization: TextCapitalization.sentences,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontSize: inputSize,
                          color: tk.text,
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
                          hintStyle: theme.textTheme.titleLarge?.copyWith(
                            fontSize: inputSize,
                            color: tk.textMuted,
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
                      borderRadius: BorderRadius.circular(tk.radiusMd),
                      child: _RollButton(enabled: hasText, onTap: () => unawaited(_send()), size: inputSize * 2.3),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        SizedBox(height: short ? 14 : (wide ? 32 : 26)),
        if (!short) _rise(0.4, 0.9, Text(t.aiComposer.quickStart, style: _sectionTitle(isTv, color: tk.text))),
        if (!short) SizedBox(height: isTv ? 12 : ForkSpacing.of(context).titleGap),
        _rise(
          0.45,
          1,
          SizedBox(
            height: 44,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              itemCount: chips.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final chip = chips[i];
                return Center(
                  child: Pressable(
                    longPress: false,
                    borderRadius: BorderRadius.circular(MonoTokens.radiusFull),
                    child: FocusableFilterChip(
                      focusNode: _chipNode(i),
                      icon: chip.icon,
                      label: chip.label,
                      onPressed: () => unawaited(_send(chip.request)),
                      onNavigateLeft: i > 0 ? () => _chipNode(i - 1).requestFocus() : null,
                      onNavigateRight: i < chips.length - 1 ? () => _chipNode(i + 1).requestFocus() : null,
                      onNavigateUp: _fieldFocus.requestFocus,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  /// The written answer, as a card of programme notes, with Done and Ask
  /// another.
  Widget _answerView(bool isTv, bool wide) {
    final theme = Theme.of(context);
    final tk = tokens(context);
    final pick = _pick;
    final gutter = _gutter(isTv);
    return SafeArea(
      key: const ValueKey('answer'),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: wide ? 820 : 640),
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(gutter, 56, gutter, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    SizedBox(
                      width: isTv ? 40 : 32,
                      height: isTv ? 35 : 28,
                      child: CustomPaint(painter: _ClapperPainter(1, tk.accent, tk.surface)),
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        widget.notesTitle ?? t.aiComposer.programNotes,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _sectionTitle(isTv, color: tk.text),
                      ),
                    ),
                  ],
                ),
                if (widget.about case final about?) ...[
                  const SizedBox(height: 14),
                  _AboutChip(title: about, large: isTv),
                ],
                const SizedBox(height: 16),
                Text(
                  '“${_controller.text.trim()}”',
                  style: theme.textTheme.titleMedium?.copyWith(color: tk.textMuted, fontStyle: FontStyle.italic),
                ),
                const SizedBox(height: 14),
                Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: EdgeInsets.all(isTv ? 28 : 20),
                    child: Text(
                      _answer ?? '',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: tk.text,
                        fontSize: isTv ? 22 : (wide ? 18 : 16),
                        height: 1.45,
                      ),
                    ),
                  ),
                ),
                if (pick != null) ...[
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Icon(Symbols.movie_rounded, color: tk.textMuted, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          t.aiComposer.picksInTab,
                          style: theme.textTheme.bodyMedium?.copyWith(color: tk.textMuted),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 22),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    FocusableButton(
                      focusNode: _doneFocus,
                      autofocus: true,
                      onPressed: _closeAnswer,
                      onNavigateRight: _askAnotherFocus.requestFocus,
                      child: Pressable(
                        longPress: false,
                        borderRadius: BorderRadius.circular(MonoTokens.radiusFull),
                        child: FilledButton(onPressed: _closeAnswer, child: Text(t.aiComposer.done)),
                      ),
                    ),
                    FocusableButton(
                      focusNode: _askAnotherFocus,
                      onPressed: _askAnother,
                      onNavigateLeft: _doneFocus.requestFocus,
                      child: Pressable(
                        longPress: false,
                        borderRadius: BorderRadius.circular(MonoTokens.radiusFull),
                        child: OutlinedButton(onPressed: _askAnother, child: Text(t.aiComposer.askAnother)),
                      ),
                    ),
                  ],
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
    final media = MediaQuery.of(context);
    final room = size.height - media.viewInsets.bottom - media.padding.vertical;
    // The strip takes about a third of the height, so short screens fit.
    final frameH = math.min(isTv ? 260.0 : (wide ? 230.0 : 170.0), math.max(96.0, room * 0.3));
    final frameW = frameH * 2 / 3;
    _pitch = frameW + frameW * 0.12;
    final jam = _jam;
    final slate = jam != null ? t.aiComposer.jammed : (_take >= _takes.length ? t.aiComposer.wrap : _takes[_take]);
    final pick = _pick;
    final tk = tokens(context);
    final error = theme.colorScheme.error;
    final slateColor = jam != null ? error : (_landed ? tk.accent : tk.text);
    return SafeArea(
      key: const ValueKey('thinking'),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: isTv ? 48 : 36,
                  height: isTv ? 42 : 32,
                  child: AnimatedBuilder(
                    animation: _clap,
                    builder: (context, _) => CustomPaint(
                      painter: _ClapperPainter(Curves.easeInCubic.transform(_clap.value), slateColor, tk.surface),
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Flexible(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    transitionBuilder: (child, a) => FadeTransition(
                      opacity: a,
                      child: SlideTransition(
                        position: Tween(begin: const Offset(0, 0.4), end: Offset.zero).animate(a),
                        child: child,
                      ),
                    ),
                    child: FittedBox(
                      key: ValueKey(slate),
                      fit: BoxFit.scaleDown,
                      child: Text(slate, maxLines: 1, style: _sectionTitle(isTv, color: slateColor)),
                    ),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: isTv ? 28 : 20),
          AnimatedBuilder(
            animation: _judder,
            builder: (context, child) {
              final v = _judder.value;
              // A decaying shudder, as if the film caught in the gate.
              final dx = _judder.isAnimating ? math.sin(v * math.pi * 9) * 14 * (1 - v) : 0.0;
              return Transform.translate(offset: Offset(dx, 0), child: child);
            },
            child: _FilmStrip(
              items: widget.posters,
              position: _stripPos,
              frameW: frameW,
              frameH: frameH,
              pitch: _pitch,
              pickSlot: _pickSlot,
              pick: pick,
              flash: _flash,
              gate: jam != null ? error : (_landed ? tk.accent : tk.text.withValues(alpha: 0.7)),
            ),
          ),
          SizedBox(height: isTv ? 28 : 20),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: _gutter(isTv)),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: jam != null
                  ? Column(
                      key: const ValueKey('jam'),
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          jam,
                          textAlign: TextAlign.center,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(color: tk.textMuted),
                        ),
                        const SizedBox(height: 18),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            FocusableButton(
                              focusNode: _retryFocus,
                              autofocus: true,
                              onPressed: () => unawaited(_roll(_controller.text.trim())),
                              onNavigateRight: _editFocus.requestFocus,
                              child: Pressable(
                                longPress: false,
                                child: FilledButton.icon(
                                  onPressed: () => unawaited(_roll(_controller.text.trim())),
                                  icon: const Icon(Symbols.replay_rounded),
                                  label: Text(t.common.retry),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            FocusableButton(
                              focusNode: _editFocus,
                              onPressed: _backToEdit,
                              onNavigateLeft: _retryFocus.requestFocus,
                              child: Pressable(
                                longPress: false,
                                child: OutlinedButton.icon(
                                  onPressed: _backToEdit,
                                  icon: const Icon(Symbols.edit_rounded),
                                  label: Text(t.aiComposer.edit),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    )
                  : _landed && pick != null
                  ? Text(
                      pick.displayTitle,
                      key: const ValueKey('pick'),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: (isTv ? theme.textTheme.displaySmall : theme.textTheme.headlineMedium)?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: tk.text,
                      ),
                    )
                  : Text(
                      '“${_controller.text.trim()}”',
                      key: const ValueKey('request'),
                      textAlign: TextAlign.center,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleLarge?.copyWith(color: tk.textMuted, fontStyle: FontStyle.italic),
                    ),
            ),
          ),
          const SizedBox(height: 18),
          if (jam == null && !_landed) ...[
            FocusableButton(
              focusNode: _browseFocus,
              autofocus: isTv,
              onPressed: _continueBrowsing,
              child: Pressable(
                longPress: false,
                borderRadius: BorderRadius.circular(MonoTokens.radiusFull),
                child: OutlinedButton(onPressed: _continueBrowsing, child: Text(t.aiComposer.continueBrowsing)),
              ),
            ),
            const SizedBox(height: 10),
            Text(t.aiComposer.keepsRunning, style: theme.textTheme.bodySmall?.copyWith(color: tk.textMuted)),
          ],
        ],
      ),
    );
  }
}

/// "About: <title>" — what an Ask about this question is about.
class _AboutChip extends StatelessWidget {
  const _AboutChip({required this.title, required this.large});
  final String title;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final tk = tokens(context);
    final textTheme = Theme.of(context).textTheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tk.surface,
        borderRadius: BorderRadius.circular(MonoTokens.radiusFull),
        border: Border.all(color: tk.outline),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: large ? 16 : 12, vertical: large ? 8 : 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Symbols.local_movies_rounded, color: tk.accent, size: large ? 20 : 16, fill: 1),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                t.aiComposer.aboutChip(title: title),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: (large ? textTheme.titleMedium : textTheme.labelLarge)?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: tk.text,
                ),
              ),
            ),
          ],
        ),
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

/// Send: a "roll camera" key, filled with the accent once there's text.
class _RollButton extends StatelessWidget {
  const _RollButton({required this.enabled, required this.onTap, required this.size});
  final bool enabled;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    final tk = tokens(context);
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(tk.radiusMd),
          // Solid either way, so posters never show through it.
          color: enabled ? tk.accent : Color.alphaBlend(tk.text.withValues(alpha: 0.08), tk.bg),
          border: Border.all(color: enabled ? tk.accent : tk.outline, width: 1.5),
        ),
        child: Icon(
          Symbols.play_arrow_rounded,
          fill: 1,
          color: enabled ? Theme.of(context).colorScheme.onPrimary : tk.textMuted,
          size: size * 0.6,
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
    required this.gate,
  });

  final List<MediaItem> items;
  final ValueListenable<double> position;
  final double frameW;
  final double frameH;
  final double pitch;
  final int? pickSlot;
  final MediaItem? pick;
  final Animation<double> flash;
  final Color gate;

  MediaItem? _itemAt(int slot) {
    if (slot == pickSlot && pick != null) return pick;
    if (items.isEmpty) return null;
    return items[slot % items.length];
  }

  @override
  Widget build(BuildContext context) {
    final band = frameH * 0.16;
    final height = frameH + band * 2;
    final tk = tokens(context);
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
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: _SprocketPainter(position, pitch, band, base: tk.surface, hole: tk.bg),
                  ),
                ),
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
              // Frames off the gate fade into the page.
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          tk.bg,
                          tk.bg.withValues(alpha: 0.6),
                          tk.bg.withValues(alpha: 0),
                          tk.bg.withValues(alpha: 0.6),
                          tk.bg,
                        ],
                        stops: const [0, 0.3, 0.5, 0.7, 1],
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
                      CustomPaint(painter: _GatePainter(gate)),
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: AnimatedBuilder(
                          animation: flash,
                          builder: (context, _) {
                            final v = flash.isAnimating ? (1 - flash.value) * 0.7 : 0.0;
                            return ColoredBox(color: tk.text.withValues(alpha: v));
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
      final tk = tokens(context);
      child = ColoredBox(
        color: Color.alphaBlend(tk.text.withValues(alpha: 0.06), tk.surface),
        child: Center(
          child: Text(
            '${number.abs() % 99 + 1}',
            style: Theme.of(
              context,
            ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700, color: tk.text.withValues(alpha: 0.24)),
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

/// The strip's film base: a [base] band with rounded sprocket holes top and
/// bottom, scrolling with [position].
class _SprocketPainter extends CustomPainter {
  _SprocketPainter(this.position, this.pitch, this.band, {required this.base, required this.hole})
    : super(repaint: position);
  final ValueListenable<double> position;
  final double pitch;
  final double band;
  final Color base;
  final Color hole;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = base);
    final hole = Paint()..color = this.hole;
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
  bool shouldRepaint(_SprocketPainter old) =>
      old.pitch != pitch || old.band != band || old.base != base || old.hole != hole;
}

/// Projector-gate corner brackets: the accent once the strip lands, the
/// error colour on a jam.
class _GatePainter extends CustomPainter {
  _GatePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.square
      ..color = color;
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
  bool shouldRepaint(_GatePainter old) => old.color != color;
}

/// The composer's mark, drawing itself as the page opens: an aperture
/// ring, six blade lines inside it, then a play triangle that fills, all
/// in [color].
class _MarkPainter extends CustomPainter {
  _MarkPainter(this.t, this.color);
  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final draw = Curves.easeOutCubic.transform((t / 0.6).clamp(0.0, 1.0));
    final fill = ((t - 0.5) / 0.25).clamp(0.0, 1.0);
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2 - 1.5;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;

    final ring = Path()..addArc(Rect.fromCircle(center: c, radius: r), -math.pi / 2, math.pi * 2 - 0.0001);
    final blades = Path();
    for (var i = 0; i < 6; i++) {
      final a = -math.pi / 2 + i * math.pi / 3;
      final from = c + Offset(math.cos(a), math.sin(a)) * r;
      final to = c + Offset(math.cos(a + math.pi * 0.62), math.sin(a + math.pi * 0.62)) * r * 0.52;
      blades
        ..moveTo(from.dx, from.dy)
        ..lineTo(to.dx, to.dy);
    }
    final tri = r * 0.42;
    final play = Path()
      ..moveTo(c.dx - tri * 0.45, c.dy - tri * 0.8)
      ..lineTo(c.dx + tri * 0.9, c.dy)
      ..lineTo(c.dx - tri * 0.45, c.dy + tri * 0.8)
      ..close();

    // Ring first, then blades, then the triangle, each drawn along its path.
    _trace(canvas, ring, (draw / 0.5).clamp(0.0, 1.0), stroke);
    _trace(canvas, blades, ((draw - 0.35) / 0.4).clamp(0.0, 1.0), stroke..color = color.withValues(alpha: 0.55));
    _trace(canvas, play, ((draw - 0.55) / 0.45).clamp(0.0, 1.0), stroke..color = color);
    if (fill > 0) canvas.drawPath(play, Paint()..color = color.withValues(alpha: fill));
  }

  static void _trace(Canvas canvas, Path path, double p, Paint paint) {
    if (p <= 0) return;
    for (final m in path.computeMetrics()) {
      canvas.drawPath(m.extractPath(0, m.length * p), paint);
    }
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.t != t || old.color != color;
}

/// A clapperboard: a slate with a striped clapstick hinged at its top left,
/// open at [closed] 0 and shut at 1, drawn in [color] on a [fill] slate.
class _ClapperPainter extends CustomPainter {
  _ClapperPainter(this.closed, this.color, this.fill);
  final double closed;
  final Color color;
  final Color fill;

  @override
  void paint(Canvas canvas, Size size) {
    final stickH = size.height * 0.24;
    final board = Rect.fromLTWH(0, stickH + 2, size.width, size.height - stickH - 2);
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..color = color;
    canvas.drawRRect(RRect.fromRectAndRadius(board, const Radius.circular(3)), Paint()..color = fill);
    canvas.drawRRect(RRect.fromRectAndRadius(board, const Radius.circular(3)), line);
    // Slate lines.
    for (final f in [0.45, 0.72]) {
      final y = board.top + board.height * f;
      canvas.drawLine(
        Offset(board.left + 5, y),
        Offset(board.right - 5, y),
        line..color = color.withValues(alpha: 0.5),
      );
    }
    line.color = color;

    // The clapstick, swung open by up to 28 degrees around its hinge.
    canvas.save();
    canvas.translate(0, stickH);
    canvas.rotate(-(1 - closed) * 28 * math.pi / 180);
    final stick = Rect.fromLTWH(0, -stickH, size.width, stickH);
    canvas.clipRRect(RRect.fromRectAndRadius(stick, const Radius.circular(2)));
    canvas.drawRect(stick, Paint()..color = fill);
    final stripe = Paint()..color = color;
    final w = size.width / 5;
    for (var i = 0; i < 6; i += 2) {
      final x = i * w;
      canvas.drawPath(
        Path()
          ..moveTo(x, 0)
          ..lineTo(x + w * 0.7, -stickH)
          ..lineTo(x + w * 1.7, -stickH)
          ..lineTo(x + w, 0)
          ..close(),
        stripe,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ClapperPainter old) => old.closed != closed || old.color != color || old.fill != fill;
}

/// 75% desaturated, then dimmed to 40%.
const _dimGrey = <double>[
  0.4 * (0.25 + 0.75 * 0.2126), 0.4 * 0.75 * 0.7152, 0.4 * 0.75 * 0.0722, 0, 0, //
  0.4 * 0.75 * 0.2126, 0.4 * (0.25 + 0.75 * 0.7152), 0.4 * 0.75 * 0.0722, 0, 0, //
  0.4 * 0.75 * 0.2126, 0.4 * 0.75 * 0.7152, 0.4 * (0.25 + 0.75 * 0.0722), 0, 0, //
  0, 0, 0, 1, 0,
];

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
        // Dimmed and mostly desaturated in one layer, so poster art and
        // titles don't compete with the page.
        child: ColorFiltered(
          colorFilter: const ColorFilter.matrix(_dimGrey),
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
