import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../utils/app_logger.dart';

/// Fork: spoken AI requests through the system's speech recogniser (Android
/// phones and TVs). The recogniser shows its own listening UI and owns the
/// microphone, so the app needs no audio permission.
abstract final class VoiceInput {
  static const MethodChannel _channel = MethodChannel('com.plezy/voice_input');

  static Future<bool>? _available;

  /// Whether this device can take a spoken request (checked once).
  static Future<bool> available() => _available ??= _check();

  static Future<bool> _check() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      return await _channel.invokeMethod<bool>('isAvailable') ?? false;
    } catch (e) {
      appLogger.d('Voice input: unavailable', error: e);
      return false;
    }
  }

  /// What the user said, or null when they backed out or nothing was heard.
  static Future<String?> listen({String? prompt}) async {
    try {
      return await _channel.invokeMethod<String>('listen', {'prompt': prompt});
    } catch (e) {
      appLogger.w('Voice input failed', error: e);
      return null;
    }
  }
}
