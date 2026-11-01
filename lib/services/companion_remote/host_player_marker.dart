import 'package:flutter/foundation.dart';

/// Fork, now playing: the skip marker the host's player is in ('intro' or
/// 'credits'), published by the video controls so a connected phone can
/// offer Skip intro / Skip credits.
abstract final class HostPlayerMarker {
  static final ValueNotifier<String?> current = ValueNotifier(null);
}
