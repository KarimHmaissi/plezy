import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:plezy_brain/plezy_brain.dart';

import '../../media/ids.dart';
import '../../media/media_item.dart';
import '../../media/media_server_client.dart';
import '../../utils/app_logger.dart';
import '../brain/history_brain.dart';
import '../customisation/customisation_store.dart';
import 'ai_rows.dart' show pickFetchTimeout;

/// Fork: one week of watching (Monday to Sunday), counted from the history
/// brain: no AI call, so it costs nothing.
class WatchWeek {
  const WatchWeek({
    required this.start,
    required this.minutes,
    required this.films,
    required this.episodes,
    required this.top,
    this.finished = const [],
    this.started = const [],
    this.bigNight,
    this.topGenre,
  });

  /// Monday, midnight local time.
  final DateTime start;
  DateTime get end => DateTime(start.year, start.month, start.day + 7);

  final int minutes;
  final int films;
  final int episodes;

  /// What took the most time, most first.
  final List<TitleProfile> top;

  /// Shows caught up on this week.
  final List<TitleProfile> finished;

  /// Shows begun this week (and not finished).
  final List<TitleProfile> started;

  /// The weekday (DateTime.monday...) that held most of the week's watching.
  final int? bigNight;
  final String? topGenre;

  /// The most posters, finished and started titles a card shows.
  static const int maxTop = 10;

  /// Which week the card shows on [now]: on Sunday the week ending today, on
  /// Monday and Tuesday the week just gone, otherwise none.
  static DateTime? shownOn(DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    final monday = DateTime(today.year, today.month, today.day - (today.weekday - DateTime.monday));
    return switch (now.weekday) {
      DateTime.sunday => monday,
      DateTime.monday || DateTime.tuesday => DateTime(monday.year, monday.month, monday.day - 7),
      _ => null,
    };
  }

  /// The week from [start] in [profiles]; null when nothing was watched.
  static WatchWeek? of(List<TitleProfile> profiles, DateTime start, {required DateTime now}) {
    final end = DateTime(start.year, start.month, start.day + 7);
    bool inWeek(DateTime d) {
      final local = d.toLocal();
      return !local.isBefore(start) && local.isBefore(end);
    }

    var films = 0, episodes = 0, total = 0;
    final byTitle = <TitleProfile, int>{};
    final byDay = <int, int>{};
    final byGenre = <String, int>{};
    final finished = <TitleProfile>[];
    final started = <TitleProfile>[];
    for (final p in profiles) {
      final watches = p.watches.where(inWeek).toList();
      if (watches.isEmpty) continue;
      final each = p.runtimeMinutes ?? (p.isMovie ? fallbackMovieMinutes : fallbackEpisodeMinutes);
      final minutes = watches.length * each;
      if (p.isMovie) {
        films += watches.length;
      } else {
        episodes += watches.length;
      }
      total += minutes;
      byTitle[p] = minutes;
      for (final w in watches) {
        byDay.update(w.toLocal().weekday, (m) => m + each, ifAbsent: () => each);
      }
      for (final g in p.genres.take(2)) {
        byGenre.update(g, (m) => m + minutes, ifAbsent: () => minutes);
      }
      if (!p.isMovie) {
        if (p.progress(now) == ShowProgress.finished) {
          finished.add(p);
        } else if (inWeek(p.firstWatched!)) {
          started.add(p);
        }
      }
    }
    if (byTitle.isEmpty) return null;
    int byMinutes(TitleProfile a, TitleProfile b) => byTitle[b]!.compareTo(byTitle[a]!);
    final days = byDay.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final genres = byGenre.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return WatchWeek(
      start: start,
      minutes: total,
      films: films,
      episodes: episodes,
      top: (byTitle.keys.toList()..sort(byMinutes)).take(maxTop).toList(),
      finished: (finished..sort(byMinutes)).take(maxTop).toList(),
      started: (started..sort(byMinutes)).take(maxTop).toList(),
      // Only a pattern when one day stood out across a few days of watching.
      bigNight: days.length >= 3 && days.first.value >= total * 0.4 ? days.first.key : null,
      topGenre: genres.isEmpty ? null : genres.first.key,
    );
  }
}

/// Fork: "Your week in watching" on the AI page, Sunday to Tuesday. Hidden
/// for the rest of the week once dismissed.
abstract final class AiWeek {
  static const String dismissedKey = 'ai.week.dismissed';

  static ({DateTime start, List<MediaItem> items})? _posters;

  /// This week's card with its posters, or null when there's none to show.
  static Future<({WatchWeek week, List<MediaItem> items})?> load({
    required MediaServerClient? Function(ServerId serverId) clientFor,
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    final start = WatchWeek.shownOn(at);
    if (start == null) return null;
    final store = await Customisation.store;
    if (await store.readSetting(dismissedKey) == _day(start)) return null;
    final week = WatchWeek.of(await HistoryBrain.instance.watchedProfiles(), start, now: at);
    if (week == null) return null;
    final cached = _posters;
    if (cached != null && cached.start == start) return (week: week, items: cached.items);
    final items = await _fetch(week.top, clientFor);
    _posters = (start: start, items: items);
    return (week: week, items: items);
  }

  /// Hide this week's card until next week's.
  static Future<void> dismiss(WatchWeek week) async {
    await (await Customisation.store).writeSetting(dismissedKey, _day(week.start));
  }

  static String _day(DateTime d) => d.toIso8601String().substring(0, 10);

  static Future<List<MediaItem>> _fetch(
    List<TitleProfile> titles,
    MediaServerClient? Function(ServerId serverId) clientFor,
  ) async {
    final items = await Future.wait([
      for (final p in titles)
        if (p.inLibrary && p.serverId != null && p.ratingKey != null)
          () async {
            try {
              return await clientFor(ServerId(p.serverId!))?.fetchItem(p.ratingKey!).timeout(pickFetchTimeout);
            } catch (e) {
              appLogger.d('AI week: fetching ${p.title} failed', error: e);
              return null;
            }
          }(),
    ]);
    return items.nonNulls.toList();
  }

  @visibleForTesting
  static void resetCache() => _posters = null;
}
