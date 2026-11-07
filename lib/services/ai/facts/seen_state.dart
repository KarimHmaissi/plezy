import 'dart:math' as math;

import 'package:plezy_brain/plezy_brain.dart';

import '../ai_watch_state.dart';

/// What kind of "seen" a title is.
enum SeenKind {
  /// No plays anywhere, no progress.
  unseen,

  /// A film watched, with real viewing dates.
  watched,

  /// Watched with no real date: a Trakt import or a Plex "mark as
  /// watched". He watched these before Plex, so it is never "no record".
  logged,

  /// A film stopped partway, or a show watched in the last 60 days.
  inProgress,

  /// A show tried for an episode or two, long ago.
  sampled,

  /// A show not caught up, last watched 60-180 days ago.
  paused,

  /// A show given a real go, untouched for 180 days.
  dropped,

  /// A show caught up.
  finished,
}

/// Where an undated watch was logged.
enum LoggedVia { trakt, plexUndated }

/// One honest seen state per title, merged from the library row (this
/// copy's Plex counts) and the history brain (every Plex copy and Trakt,
/// imports and marks included). The Reel's "unseen only" rule and every
/// "Seen" badge read this, so it claims only what the data shows.
class SeenState {
  const SeenState({
    required this.kind,
    this.last,
    this.eps,
    this.total,
    this.rewatched = false,
    this.loggedVia = const {},
  });

  static const SeenState unseen = SeenState(kind: SeenKind.unseen);

  final SeenKind kind;

  /// The newest real viewing date, when there is one.
  final DateTime? last;

  /// Shows: distinct episodes watched, and episodes there are.
  final int? eps;
  final int? total;
  final bool rewatched;

  /// How undated watches were logged.
  final Set<LoggedVia> loggedVia;

  /// No plays, no progress, nothing logged: safe for "unseen only" pools.
  bool get isUnseen => kind == SeenKind.unseen;

  /// A card badge, or null for unseen. "Seen" only when the title was
  /// really watched or logged; shows part-way read "Started".
  String? get badge => switch (kind) {
    SeenKind.unseen => null,
    SeenKind.watched || SeenKind.logged || SeenKind.finished => 'Seen',
    SeenKind.inProgress => 'Watching',
    SeenKind.sampled || SeenKind.paused || SeenKind.dropped => 'Started',
  };

  /// One line for a model prompt or a details row:
  /// "watched Oct 2026" · "logged as seen (Trakt)" · "marked watched (Plex)"
  /// · "38/62 eps, watching" · "1/59 eps, sampled" · "unseen".
  String line() {
    final again = rewatched ? ', rewatched' : '';
    switch (kind) {
      case SeenKind.unseen:
        return 'unseen';
      case SeenKind.watched:
        final at = last;
        final when = at == null ? 'watched$again' : 'watched ${monthName(at.month)} ${at.year}$again';
        return eps == null ? when : '${_eps()}, $when';
      case SeenKind.logged:
        if (eps != null) return '${_eps()}, ${_logged()}$again';
        return '${_logged()}$again';
      case SeenKind.inProgress:
        return eps == null ? 'in progress' : '${_eps()}, watching';
      case SeenKind.sampled:
        return '${_eps()}, sampled';
      case SeenKind.paused:
        return '${_eps()}, paused';
      case SeenKind.dropped:
        return '${_eps()}, dropped';
      case SeenKind.finished:
        return '${_eps()}, finished$again';
    }
  }

  String _logged() {
    final trakt = loggedVia.contains(LoggedVia.trakt), plex = loggedVia.contains(LoggedVia.plexUndated);
    if (trakt && plex) return 'logged as seen (Trakt, Plex)';
    if (plex) return 'marked watched (Plex)';
    if (trakt) return 'logged as seen (Trakt)';
    return 'logged as seen';
  }

  String _eps() {
    final n = eps ?? 0;
    final t = total;
    return t == null || t == 0 ? '$n eps' : '${math.min(n, t)}/$t eps';
  }

  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  static String monthName(int month) => _months[(month - 1).clamp(0, 11)];

  /// The merged state from a library [row] state (null when the title isn't
  /// on the servers) and the brain's [profile] (null when it never was
  /// watched anywhere).
  factory SeenState.of({WatchState? row, TitleProfile? profile, required DateTime now}) {
    final isShow = profile != null ? !profile.isMovie : (row?.isShow ?? false);
    final via = <LoggedVia>{
      for (final v in profile?.bulkVia ?? const <String>{})
        if (v == 'trakt') LoggedVia.trakt else if (v == 'plexUndated') LoggedVia.plexUndated,
    };
    final rewatched = profile?.rewatched ?? false;

    if (isShow) {
      final eps = math.max(row?.episodesWatched ?? 0, profile?.episodesWatched ?? 0);
      final total = row?.episodeCount ?? profile?.episodeCount;
      if (eps == 0 && (profile?.plays ?? 0) == 0) return SeenState.unseen;
      final last = profile?.lastWatched ?? row?.lastSeen;
      final progress = profile != null
          ? _withCounts(profile, eps, total).progress(now)
          : (total != null && total > 0 && eps >= total * 0.9 ? ShowProgress.finished : ShowProgress.unknown);
      final kind = switch (progress) {
        ShowProgress.finished => SeenKind.finished,
        ShowProgress.inProgress => SeenKind.inProgress,
        ShowProgress.paused => SeenKind.paused,
        ShowProgress.dropped => SeenKind.dropped,
        ShowProgress.sampled => SeenKind.sampled,
        // Episodes known but no dated watch to place them in time.
        ShowProgress.none || ShowProgress.unknown => last == null ? SeenKind.logged : SeenKind.watched,
      };
      return SeenState(kind: kind, last: last, eps: eps, total: total, rewatched: rewatched, loggedVia: via);
    }

    final realLast = profile?.lastWatched ?? row?.lastSeen;
    // The brain sorts dated watches from bulk marks across every copy, so it
    // decides when it knows the title; a lone row decides by its own date.
    final watched = profile != null ? profile.watches.isNotEmpty : (row?.seen ?? false) && row?.lastSeen != null;
    if (watched) return SeenState(kind: SeenKind.watched, last: realLast, rewatched: rewatched, loggedVia: via);
    final logged = (profile?.bulkPlays ?? 0) > 0 || (row?.seen ?? false);
    if (logged) {
      // A Plex view count with no date is a Plex mark even when the brain
      // hasn't been rebuilt with its sources yet.
      final v = via.isEmpty && (row?.seen ?? false) ? {LoggedVia.plexUndated} : via;
      return SeenState(kind: SeenKind.logged, rewatched: rewatched, loggedVia: v);
    }
    if (row?.inProgress ?? false) return const SeenState(kind: SeenKind.inProgress);
    return SeenState.unseen;
  }

  /// [p] with the merged episode counts, for its progress rules.
  static TitleProfile _withCounts(TitleProfile p, int eps, int? total) => TitleProfile(
    id: p.id,
    kind: p.kind,
    title: p.title,
    watches: p.watches,
    bulkPlays: p.bulkPlays,
    episodesWatched: eps,
    episodeCount: total,
  );

  @override
  bool operator ==(Object other) =>
      other is SeenState &&
      other.kind == kind &&
      other.last == last &&
      other.eps == eps &&
      other.total == total &&
      other.rewatched == rewatched &&
      other.loggedVia.length == loggedVia.length &&
      other.loggedVia.containsAll(loggedVia);

  @override
  int get hashCode => Object.hash(kind, last, eps, total, rewatched, loggedVia.length);

  @override
  String toString() => 'SeenState(${line()})';
}
