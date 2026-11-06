import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';

import '../utils/app_logger.dart';
import '../utils/connectivity_link_type.dart';
import '../utils/platform_detector.dart';
import 'connectivity_probe.dart';
import 'reel/reel_playback_profile.dart';
import 'settings_service.dart';

/// The Reel's link from a connectivity snapshot: mobile data only when it is
/// the only link (the app's one definition of metered), offline only when
/// the platform says so outright. Anything else, unknown included, is
/// treated as unmetered, as the rest of the app does.
ReelLink reelLinkOf(List<ConnectivityResult> results) {
  if (results.isCellularOnly) return ReelLink.cellular;
  if (results.isNotEmpty && results.every((r) => r == ConnectivityResult.none)) return ReelLink.offline;
  return ReelLink.unmetered;
}

/// Fork (Reel, plan V2-16): the device's current [ReelPlaybackProfile],
/// rebuilt when the screen's metrics change (the Fold switching screens or
/// turning), when the network changes, and when the Reel's mobile-data pref
/// does. Lives outside `lib/services/reel/` because it reads the app's
/// platform, connectivity and settings services.
///
/// One per app, started on first use: a metrics observer and a share of the
/// app's connectivity stream cost next to nothing, and the profile is ready
/// before the Reel's first card.
class ReelPlaybackWatcher extends ValueNotifier<ReelPlaybackProfile> with WidgetsBindingObserver {
  @visibleForTesting
  ReelPlaybackWatcher({
    required this._isTV,
    required this._cellular,
    this._cellularChanged,
    Stream<List<ConnectivityResult>>? linkChanges,
    Future<List<ConnectivityResult>> Function()? checkLink,
  }) : super(ReelPlaybackProfile.standard) {
    WidgetsBinding.instance.addObserver(this);
    _cellularChanged?.addListener(_rebuild);
    _links = linkChanges?.listen((r) {
      _heard = true;
      _onLink(r);
    });
    // The first snapshot, unless a change already said something newer.
    if (checkLink != null) {
      unawaited(checkLink().then((r) => _heard ? null : _onLink(r), onError: (Object _) {}));
    }
    _rebuild();
  }

  static ReelPlaybackWatcher? _instance;

  /// The app's watcher, started on first use.
  static ReelPlaybackWatcher get instance => _instance ??= _app();

  static ReelPlaybackWatcher _app() {
    final settings = SettingsService.instanceOrNull;
    return ReelPlaybackWatcher(
      isTV: PlatformDetector.isTV,
      cellular: () => SettingsService.instanceOrNull?.read(SettingsService.reelCellular) ?? ReelCellular.normal,
      cellularChanged: settings?.listenableOf(SettingsService.reelCellular),
      linkChanges: ConnectivityProbe.changes,
      checkLink: ConnectivityProbe.check,
    );
  }

  final bool Function() _isTV;
  final ReelCellular Function() _cellular;
  final Listenable? _cellularChanged;
  StreamSubscription<List<ConnectivityResult>>? _links;
  ReelLink _link = ReelLink.unmetered;
  bool _heard = false;
  bool _disposed = false;

  void _onLink(List<ConnectivityResult> results) {
    _link = reelLinkOf(results);
    _rebuild();
  }

  @override
  void didChangeMetrics() => _rebuild();

  void _rebuild() {
    if (_disposed) return;
    final dispatcher = WidgetsBinding.instance.platformDispatcher;
    final view = dispatcher.implicitView ?? dispatcher.views.firstOrNull;
    final ratio = view?.devicePixelRatio ?? 1;
    final next = ReelPlaybackProfile.from(
      tv: _isTV(),
      size: view == null || ratio <= 0 ? Size.zero : view.physicalSize / ratio,
      devicePixelRatio: ratio,
      link: _link,
      dataSaver: _cellular() != ReelCellular.normal,
    );
    if (next == value) return;
    appLogger.d('Reel: $next');
    value = next;
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _cellularChanged?.removeListener(_rebuild);
    unawaited(_links?.cancel());
    super.dispose();
  }
}
