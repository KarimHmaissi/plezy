import 'dart:math';

/// Episodes watched within this window sit out of a random pick.
const Duration comfortRecentlyWatchedWindow = Duration(days: 30);

/// Whether an episode last viewed at [lastViewedAtSeconds] (epoch seconds, as
/// media servers report it) was watched within [window] of [now].
bool watchedWithin(int? lastViewedAtSeconds, Duration window, {DateTime? now}) {
  if (lastViewedAtSeconds == null) return false;
  final watchedAt = DateTime.fromMillisecondsSinceEpoch(lastViewedAtSeconds * 1000);
  return (now ?? DateTime.now()).difference(watchedAt) < window;
}

/// A random pick: the show it came from and the episode to play.
typedef ComfortPick<S, E> = ({S show, E episode});

/// Pick a random episode, giving every show an equal chance.
///
/// Shows are tried in random order. A show with no episodes (not on any of
/// the user's servers, or [episodesFor] failed) is skipped, so a show is only
/// ever chosen when there is something of it to play. Within the chosen show
/// the episode is uniform among those [isRecentlyWatched] rejects; a show
/// whose episodes were all watched recently is passed over. If every playable
/// show was watched recently, recency is ignored rather than returning
/// nothing. Returns null when no show has any episode.
///
/// [episodesFor] is called lazily, one show at a time, so a typical pick
/// fetches a single show's episodes.
Future<ComfortPick<S, E>?> pickComfortEpisode<S, E>({
  required List<S> shows,
  required Future<List<E>> Function(S show) episodesFor,
  bool Function(E episode)? isRecentlyWatched,
  Random? random,
}) async {
  final rng = random ?? Random();
  final order = [...shows]..shuffle(rng);
  ComfortPick<S, E>? fallback;
  for (final show in order) {
    final List<E> episodes;
    try {
      episodes = await episodesFor(show);
    } catch (_) {
      continue;
    }
    if (episodes.isEmpty) continue;
    final fresh = isRecentlyWatched == null ? episodes : episodes.where((e) => !isRecentlyWatched(e)).toList();
    if (fresh.isNotEmpty) return (show: show, episode: fresh[rng.nextInt(fresh.length)]);
    fallback ??= (show: show, episode: episodes[rng.nextInt(episodes.length)]);
  }
  return fallback;
}
