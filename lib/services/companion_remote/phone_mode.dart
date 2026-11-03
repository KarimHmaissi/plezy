import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../providers/companion_remote_provider.dart';
import '../../utils/app_logger.dart';
import '../../utils/platform_detector.dart';
import '../ai/ai_history.dart';
import '../ai/ai_spend.dart';
import '../catalog/home_pins.dart';
import '../customisation/customisation_store.dart';
import '../settings_service.dart';
import 'mirror_sync.dart';

/// Fork: how a phone (or tablet) works. On its own, the default, it is a
/// host like a TV or desktop: its own API key, library index, history brain,
/// Home, lists and AI answers. Mirroring a TV, it shows and edits the
/// connected TV's data and sends AI requests there ([MirrorClient]). TVs and
/// desktops always work on their own. Casting and the remote work either way.
abstract final class PhoneMode {
  /// A phone or tablet (not a TV, whatever its OS).
  static bool get isHandheld =>
      !PlatformDetector.isTV() &&
      (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  /// Whether this device shows a connected TV's AI, Home and lists.
  static bool get mirrorsTv => isHandheld && SettingsService.instance.read(SettingsService.phoneMirrorsTv);

  /// Whether this device runs the AI, library index and history brain itself.
  static bool get runsOwnAi => !mirrorsTv;

  /// Bumped when [mirrorsTv] changes, after the data source has switched.
  static final ValueNotifier<int> changed = ValueNotifier(0);

  static CompanionRemoteProvider? _remote;

  /// Phone start-up: mirror the TV, or use this device's own data (copying
  /// the TV's last mirrored data in once, the first time).
  static Future<void> start(CompanionRemoteProvider remote) async {
    _remote = remote;
    if (mirrorsTv) {
      await MirrorClient.instance.start(remote);
    } else {
      await _adoptMirrorOnce();
    }
  }

  /// Switch modes from Settings. Takes effect straight away: screens reload
  /// from the new data source.
  static Future<void> setMirrorsTv(bool value) async {
    if (value == mirrorsTv) return;
    await SettingsService.instance.write(SettingsService.phoneMirrorsTv, value);
    final remote = _remote;
    if (value) {
      if (remote != null) await MirrorClient.instance.start(remote);
    } else {
      MirrorClient.instance.stop();
      Customisation.useLocal();
      await _adoptMirrorOnce();
    }
    await HomePinsController.instance.ensureLoaded(refresh: true);
    changed.value++;
  }

  /// A phone that used to mirror its TV starts with an empty database of
  /// its own: copy the last snapshot it kept (Home, lists, AI answers) so
  /// nothing seems lost. Only into an empty database, and only once.
  static Future<void> _adoptMirrorOnce() async {
    final prefs = SettingsService.instance;
    if (prefs.read(SettingsService.phoneAdoptedMirror)) return;
    try {
      final cached = await MirrorClient.readCachedSnapshot();
      if (cached != null) {
        final store = await Customisation.store;
        final empty = await store.readHomeLayout() == null && await AiHistory.count() == 0;
        if (empty) {
          // The TV's spend is the TV's: this phone counts its own.
          final settings = cached.data['settings'];
          await store.importAll({
            ...cached.data,
            if (settings is Map)
              'settings': {
                for (final MapEntry(:key, :value) in settings.entries)
                  if (key is String && !key.startsWith(AiSpend.keyPrefix)) key: value,
              },
          });
          await HomePinsController.instance.ensureLoaded(refresh: true);
          Customisation.changed.value++;
          appLogger.i('Phone: copied the TV\'s mirrored data to this device');
        }
      }
      await prefs.write(SettingsService.phoneAdoptedMirror, true);
    } catch (e) {
      // Tried again next start.
      appLogger.w('Phone: copying the mirrored data failed', error: e);
    }
  }
}
