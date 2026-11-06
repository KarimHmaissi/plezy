import 'dart:developer' as developer;

/// An async span on the Dart VM's developer trace: DevTools' performance
/// view shows it in a debug or profile build (a release build records
/// nothing). Spans that cross awaits need this rather than the trace's
/// synchronous start/finish pair, which must nest within one call stack.
class TraceSpan {
  TraceSpan(String name, {Map<String, Object?>? arguments})
    : _task = developer.TimelineTask()..start(name, arguments: arguments);

  final developer.TimelineTask _task;
  bool _ended = false;

  /// Ends the span; later calls do nothing.
  void end() {
    if (_ended) return;
    _ended = true;
    _task.finish();
  }
}
