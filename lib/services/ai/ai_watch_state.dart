import 'dart:math' as math;

import 'package:plezy_brain/plezy_brain.dart';

import '../../utils/app_logger.dart';
import '../brain/history_brain.dart';
import '../brain/history_profiles.dart';
import '../library_index/index_database.dart';

/// Fork: what the user has seen of one title, from the index row (this
/// copy's Plex plays) merged with the history brain (every Plex copy and
/// Trakt, bulk marks and imports included). "Seen" only means already
/// seen; it never keeps a title out of a rewatch ask.
class WatchState {
  const WatchState({
    this.isShow = false,
    this.seen = false,
    this.lastSeen,
    this.episodesWatched = 0,
    this.episodeCount,
    this.inProgress = false,
  });

  final bool isShow;

  /// A film seen at least once, or any episode of a show.
  final bool seen;

  /// The newest real viewing date; null when the watch was only logged
  /// (an import or "mark as watched").
  final DateTime? lastSeen;
  final int episodesWatched;
  final int? episodeCount;

  /// A film stopped partway.
  final bool inProgress;

  bool get unwatched => !seen && !inProgress;

  /// The state for a tool line: "unwatched", "in progress",
  /// "seen 2025-03", "seen (logged, no date)" or "watched 12/40 eps".
  String get label {
    final total = episodeCount ?? 0;
    if (isShow && episodesWatched > 0) {
      return total > 0 ? 'watched ${math.min(episodesWatched, total)}/$total eps' : 'watched $episodesWatched eps';
    }
    if (seen) {
      final when = lastSeen == null
          ? 'seen (logged, no date)'
          : 'seen ${lastSeen!.year}-${lastSeen!.month.toString().padLeft(2, '0')}';
      return inProgress ? '$when, in progress again' : when;
    }
    return inProgress ? 'in progress' : 'unwatched';
  }

  /// [t]'s state from its own row, merged with the brain's [profile].
  factory WatchState.of(IndexedTitle t, [TitleProfile? profile]) {
    final isShow = t.type == 'show';
    final offset = t.viewOffsetMs ?? 0;
    final rowSeen = isShow
        ? (t.watchedEpisodeCount ?? 0) > 0
        : (t.viewCount ?? 0) > 0 || (t.lastViewedAt != null && offset == 0);
    final rowDate = rowSeen && t.lastViewedAt != null
        ? DateTime.fromMillisecondsSinceEpoch(t.lastViewedAt! * 1000, isUtc: true)
        : null;
    final brainDate = profile?.lastWatched;
    return WatchState(
      isShow: isShow,
      seen: rowSeen || (profile?.watched ?? false),
      lastSeen: rowDate == null || (brainDate != null && brainDate.isAfter(rowDate)) ? brainDate : rowDate,
      episodesWatched: math.max(t.watchedEpisodeCount ?? 0, profile?.episodesWatched ?? 0),
      episodeCount: t.episodeCount ?? profile?.episodeCount,
      inProgress: !isShow && offset > 0,
    );
  }
}

/// Fork: [WatchState]s for one ask (or one list fill): the brain store is
/// loaded once, and each title's profile is read at most once. Nothing is
/// kept after the ask.
class WatchStates {
  WatchStates(this._store);

  /// Index rows only (no brain on this host).
  static final WatchStates none = WatchStates(null);

  final BrainStore? _store;
  final Map<String, TitleProfile?> _profiles = {};

  static Future<WatchStates> load(HistoryBrain? brain) async {
    if (brain == null) return none;
    try {
      return WatchStates(await brain.store);
    } catch (e) {
      appLogger.d('AI: brain watch state unavailable', error: e);
      return none;
    }
  }

  WatchState of(IndexedTitle t) {
    final store = _store;
    if (store == null) return WatchState.of(t);
    final id = LibraryRef.of(t).titleId;
    return WatchState.of(t, _profiles.putIfAbsent(id, () => _profile(store, id)));
  }

  static TitleProfile? _profile(BrainStore store, String id) {
    try {
      return store.profile(id);
    } catch (e) {
      appLogger.d('AI: brain profile unreadable', error: e);
      return null;
    }
  }

  bool seen(IndexedTitle t) => of(t).seen;
}
