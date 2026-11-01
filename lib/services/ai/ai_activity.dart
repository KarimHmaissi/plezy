import 'package:flutter/foundation.dart';

/// AI tab work the side nav shows: requests still running (the AI icon
/// pulses) and answers that arrived while the tab was hidden (a dot).
abstract final class AiActivity {
  static final ValueNotifier<int> running = ValueNotifier(0);
  static final ValueNotifier<int> unseen = ValueNotifier(0);
}
