import 'base_notifier.dart';

/// Show logos resolved after a Continue Watching fetch already returned.
///
/// Keys are [MediaItem.seriesGlobalKey] (the show an episode or season row
/// belongs to, scoped to its server); values are the show's `clearLogo` path.
/// A patch only fills rows that have no logo of their own, and never changes
/// which rows there are or their order.
class ContinueWatchingLogoPatch {
  const ContinueWatchingLogoPatch(this.logosBySeriesGlobalKey);

  final Map<String, String> logosBySeriesGlobalKey;
}

/// App-global fan-out for [ContinueWatchingLogoPatch]es. The Plex client
/// returns Continue Watching rows before its bulk show-logo lookup lands, then
/// publishes the logos here; [DiscoverProvider] patches its visible row.
///
/// Same singleton shape as [LibraryContentNotifier] / [WatchStateNotifier].
class ContinueWatchingLogoNotifier extends BaseNotifier<ContinueWatchingLogoPatch> {
  static final ContinueWatchingLogoNotifier _instance = ContinueWatchingLogoNotifier._internal();

  factory ContinueWatchingLogoNotifier() => _instance;

  ContinueWatchingLogoNotifier._internal();

  void notifyLogos(ContinueWatchingLogoPatch patch) => notify(patch);
}
