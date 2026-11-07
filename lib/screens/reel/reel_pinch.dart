import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/painting.dart';

/// Pinch to fill on the phone feed (V2-33): a two-finger pinch only.
///
/// One finger never wins with it: it stays in the arena without claiming,
/// and gives the pointer up when it lifts, so the feed's vertical paging,
/// the sideways immersive swipe, tap, double-tap and long-press all answer a
/// single finger exactly as before. The moment a second finger lands while
/// the first is still undecided, it claims both, so a pinch never pages the
/// feed. A first finger already taken by a drag (a swipe under way) is never
/// taken back: a finger added to it is not a pinch.
///
/// It reports the ratio of the two fingers' spread to where it started
/// ([onUpdate]); the pinch ends when either of the two lifts ([onEnd]).
class ReelPinchRecognizer extends OneSequenceGestureRecognizer {
  ReelPinchRecognizer({super.debugOwner, super.supportedDevices, super.allowedButtonsFilter});

  /// Two fingers are down and the pinch is ours.
  VoidCallback? onStart;

  /// The spread now over the spread at the start: above 1 is a pinch out.
  ValueChanged<double>? onUpdate;

  /// The pinch's last ratio, as one of its two fingers lifts.
  ValueChanged<double>? onEnd;

  /// Fingers still in play, by pointer, at their global position.
  final Map<int, Offset> _points = {};

  /// The two fingers of the pinch, once it has started.
  (int, int)? _pair;
  double _startSpan = 0;
  double _ratio = 1;

  /// The pinch is under way (fingers past the first two join it silently).
  bool get pinching => _pair != null;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    _points[event.pointer] = event.position;
    if (pinching) {
      // A third finger joins the pinch, so it doesn't page the feed either.
      resolvePointer(event.pointer, GestureDisposition.accepted);
      return;
    }
    if (_points.length < 2) return;
    final ids = _points.keys.take(2).toList();
    final span = (_points[ids[0]]! - _points[ids[1]]!).distance;
    // Two fingers on one spot give no ratio to read.
    if (span <= 0) return;
    _pair = (ids[0], ids[1]);
    _startSpan = span;
    _ratio = 1;
    resolve(GestureDisposition.accepted);
    onStart?.call();
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent) {
      if (!_points.containsKey(event.pointer)) return;
      _points[event.pointer] = event.position;
      final pair = _pair;
      if (pair == null || (event.pointer != pair.$1 && event.pointer != pair.$2)) return;
      final a = _points[pair.$1], b = _points[pair.$2];
      if (a == null || b == null) return;
      _ratio = (a - b).distance / _startSpan;
      onUpdate?.call(_ratio);
      return;
    }
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      final pair = _pair;
      if (pair != null && (event.pointer == pair.$1 || event.pointer == pair.$2)) {
        _pair = null;
        onEnd?.call(_ratio);
      } else if (pair == null) {
        // Never a pinch: leave this finger's arena before it is swept, so the
        // tap, double-tap or drag gets it as if this recognizer weren't here.
        resolvePointer(event.pointer, GestureDisposition.rejected);
      }
      _points.remove(event.pointer);
      stopTrackingPointer(event.pointer);
    }
  }

  @override
  void rejectGesture(int pointer) {
    // Another gesture took this finger (a drag already paging): it is out.
    _points.remove(pointer);
    stopTrackingPointer(pointer);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    if (_pair != null) onEnd?.call(_ratio);
    _pair = null;
    _points.clear();
    _ratio = 1;
  }

  @override
  String get debugDescription => 'reel pinch';
}

/// How far a pinch has to open (or close, by its inverse) to change the fit:
/// a spread 8 % wider fills, 8 % narrower fits.
const double reelPinchStep = 1.08;

/// Whether the picture fills after a pinch that ended at [ratio], starting
/// from [filled]: out past [reelPinchStep] fills, in past it fits, and a
/// pinch that barely moved leaves it as it was.
bool reelPinchFills({required bool filled, required double ratio}) {
  if (ratio >= reelPinchStep) return true;
  if (ratio <= 1 / reelPinchStep) return false;
  return filled;
}

/// The picture's scale at [fill] (0 fit, 1 fill) for a clip of [aspect] in a
/// [page]: 1 at fit; at fill, the [BoxFit.cover] scale of its fitted frame (as
/// wide as the page or as tall, the [BoxFit.contain] frame the feed lays it
/// out in), so it covers the page and what overhangs is cropped.
double reelFillZoom(Size page, double aspect, double fill) {
  if (fill <= 0 || page.isEmpty || aspect <= 0 || !aspect.isFinite) return 1;
  final frame = applyBoxFit(BoxFit.contain, Size(aspect, 1), page).destination;
  if (frame.isEmpty) return 1;
  // Cover is the larger of the two ratios: the side the frame leaves short.
  final scale = math.max(1.0, math.max(page.width / frame.width, page.height / frame.height));
  return lerpDouble(1, scale, fill.clamp(0.0, 1.0))!;
}

/// The fill [from] a pinch's start, moved by a pinch at [ratio], for a
/// picture whose full fill is [cover] times its fit: it follows the fingers
/// (a spread that doubles a picture that fills at double fills it), and a
/// picture that barely grows still answers a small pinch.
double reelPinchFill({required double from, required double ratio, required double cover}) {
  if (ratio <= 0 || !ratio.isFinite) return from;
  final reach = math.log(math.max(cover, 1.25));
  return (from + math.log(ratio) / reach).clamp(0.0, 1.0);
}
