import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../i18n/strings.g.dart';
import '../media/ids.dart';
import '../media/media_kind.dart';
import '../mixins/refreshable.dart';
import '../mixins/tab_visibility_aware.dart';
import '../models/catalog/catalog_item.dart';
import '../providers/catalog_sources_provider.dart';
import '../providers/multi_server_provider.dart';
import '../services/catalog/trakt_catalog_source.dart';
import '../services/history/history_models.dart';
import '../services/history/history_service.dart';
import '../services/history/history_stats.dart';
import '../services/library_index/library_index.dart' show IndexSource, PlexIndexSource;
import '../services/plex_client.dart';
import '../theme/fork_motion.dart';
import '../utils/app_logger.dart';
import '../utils/catalog_navigation_helper.dart';
import '../utils/media_navigation_helper.dart';
import '../widgets/optimized_media_image.dart';
import '../widgets/pressable.dart';

/// Projector-lamp amber, the page's one accent.
const _amber = Color(0xFFE5A00D);
const _display = 'Bebas Neue';

/// Fork: everything watched, from Plex and Trakt merged, with a year's (or
/// all time's) numbers on top and a month-by-month timeline below.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => HistoryScreenState();
}

class HistoryScreenState extends State<HistoryScreen>
    with ManualRefreshable, FullRefreshable, TabVisibilityAware, FocusableTab {
  final _service = HistoryService.instance;
  final _firstFocus = FocusNode(debugLabel: 'history-first');

  /// Null: all time.
  int? _year;
  bool _yearChosen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _firstFocus.dispose();
    super.dispose();
  }

  TraktCatalogSource? get _trakt => Provider.of<CatalogSourcesProvider?>(
    context,
    listen: false,
  )?.connectedSources.whereType<TraktCatalogSource>().firstOrNull;

  List<IndexSource> _plexSources() {
    final servers = context.read<MultiServerProvider>();
    return [
      for (final id in servers.onlineServerIds)
        if (servers.getClientForServer(ServerId(id)) case final PlexClient client) PlexIndexSource(client),
    ];
  }

  Future<void> _load({bool force = false}) async {
    if (!mounted) return;
    await _service.load(plex: _plexSources, trakt: _trakt?.client, force: force);
  }

  @override
  void manualRefresh() => unawaited(_load(force: true));

  @override
  void fullRefresh() => unawaited(_load(force: true));

  @override
  void primeRefresh() => unawaited(_load());

  @override
  void onTabShown() => unawaited(_load());

  @override
  void onTabHidden() {}

  @override
  void focusActiveTabIfReady() => _firstFocus.requestFocus();

  Future<void> _open(HistoryPlay play) async {
    ForkMotion.selection();
    final serverId = play.plexServerId;
    final key = play.plexRatingKey;
    if (serverId != null && key != null) {
      final client = context.read<MultiServerProvider>().getClientForServer(ServerId(serverId));
      if (client != null) {
        try {
          final item = await client.fetchItem(key);
          if (item != null && mounted) {
            await navigateToMediaItemDetails(context, item);
            return;
          }
        } catch (e) {
          appLogger.d('History: open from Plex failed', error: e);
        }
      }
    }
    if (!mounted) return;
    final tmdb = int.tryParse(play.tmdb ?? '');
    final tvdb = int.tryParse(play.tvdb ?? '');
    if (play.imdb == null && tmdb == null && tvdb == null && play.traktId == null) return;
    await navigateToCatalogItem(
      context,
      CatalogItem(
        source: CatalogSourceId.trakt,
        kind: play.isMovie ? MediaKind.movie : MediaKind.show,
        title: play.title,
        year: play.year,
        posterUrl: play.posterUrl,
        ids: CatalogItemIds(trakt: play.traktId, imdb: play.imdb, tmdb: tmdb, tvdb: tvdb),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: ValueListenableBuilder<HistoryState>(
        valueListenable: _service.state,
        builder: (context, state, _) {
          final history = state.history;
          if (history == null) {
            return _Message(
              text: state.loading || state.error == null ? t.history.loading : t.history.failed,
              busy: state.loading || state.error == null,
              onRetry: state.error != null ? () => _load(force: true) : null,
            );
          }
          final years = HistoryStats.yearsOf(history.plays);
          if (!_yearChosen && years.isNotEmpty) _year = years.first;
          final stats = HistoryStats.compute(history.plays, year: _year);
          return RefreshIndicator(
            color: _amber,
            onRefresh: ForkMotion.refreshing(() => _load(force: true)),
            child: _HistoryBody(
              state: state,
              stats: stats,
              years: years,
              year: _year,
              firstFocus: _firstFocus,
              onYear: (y) {
                ForkMotion.selection();
                setState(() {
                  _yearChosen = true;
                  _year = y;
                });
              },
              onOpen: _open,
            ),
          );
        },
      ),
    );
  }
}

/// Tests and previews: the page body for [state], without loading.
@visibleForTesting
Widget historyPreview(HistoryState state, {int? year}) {
  final stats = HistoryStats.compute(state.history!.plays, year: year);
  return ColoredBox(
    color: Colors.black,
    child: _HistoryBody(
      state: state,
      stats: stats,
      years: HistoryStats.yearsOf(state.history!.plays),
      year: year,
      firstFocus: FocusNode(),
      onYear: (_) {},
      onOpen: (_) {},
    ),
  );
}

class _HistoryBody extends StatelessWidget {
  const _HistoryBody({
    required this.state,
    required this.stats,
    required this.years,
    required this.year,
    required this.firstFocus,
    required this.onYear,
    required this.onOpen,
  });

  final HistoryState state;
  final HistoryStats stats;
  final List<int> years;
  final int? year;
  final FocusNode firstFocus;
  final ValueChanged<int?> onYear;
  final ValueChanged<HistoryPlay> onOpen;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final gutter = width < 420 ? 16.0 : 28.0;
    final groups = _byMonth(stats.plays);
    final history = state.history!;
    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverSafeArea(
          bottom: false,
          sliver: SliverPadding(
            padding: EdgeInsets.fromLTRB(gutter, 16, gutter, 0),
            sliver: SliverToBoxAdapter(
              child: Center(
                child: _PageWidth(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              year == null ? t.history.title.toUpperCase() : '${t.history.title.toUpperCase()} · $year',
                              style: const TextStyle(
                                fontFamily: _display,
                                fontSize: 40,
                                color: Colors.white,
                                height: 1,
                              ),
                            ),
                          ),
                          if (state.loading)
                            const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2, color: _amber),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _YearPicker(years: years, year: year, onYear: onYear, firstFocus: firstFocus),
                      const SizedBox(height: 20),
                      _StatsHero(stats: stats, wide: width >= 600),
                      if (stats.byMonth.isNotEmpty) ...[
                        const SizedBox(height: 28),
                        _SectionTitle(t.history.byMonth),
                        const SizedBox(height: 10),
                        _MonthStrip(stats: stats, year: year),
                      ],
                      const SizedBox(height: 28),
                      _SectionTitle(t.history.timeline),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (stats.plays.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                t.history.empty,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54),
              ),
            ),
          ),
        for (final group in groups) ...[
          SliverPadding(
            padding: EdgeInsets.fromLTRB(gutter, 18, gutter, 6),
            sliver: SliverToBoxAdapter(
              child: Center(
                child: _PageWidth(
                  child: Text(
                    '${_monthName(group.month.month)} ${group.month.year}'.toUpperCase(),
                    style: const TextStyle(fontFamily: _display, fontSize: 22, color: _amber, letterSpacing: 1),
                  ),
                ),
              ),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: gutter),
            sliver: SliverList.builder(
              itemCount: group.plays.length,
              itemBuilder: (context, i) => Center(
                child: _PageWidth(
                  child: _PlayRow(play: group.plays[i], onOpen: onOpen),
                ),
              ),
            ),
          ),
        ],
        SliverPadding(
          padding: EdgeInsets.fromLTRB(gutter, 28, gutter, 48),
          sliver: SliverToBoxAdapter(
            child: Center(
              child: _PageWidth(
                child: _Notes(state: state, stats: stats, undated: history.undated),
              ),
            ),
          ),
        ),
      ],
    );
  }

  static List<({DateTime month, List<HistoryPlay> plays})> _byMonth(List<HistoryPlay> plays) {
    final out = <({DateTime month, List<HistoryPlay> plays})>[];
    for (final p in plays) {
      final local = p.watchedAt.toLocal();
      final month = DateTime(local.year, local.month);
      if (out.isEmpty || out.last.month != month) out.add((month: month, plays: []));
      out.last.plays.add(p);
    }
    return out;
  }
}

String _monthName(int month) => const [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
][month - 1];

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    style: const TextStyle(fontFamily: _display, fontSize: 22, color: Colors.white70, letterSpacing: 1),
  );
}

class _YearPicker extends StatelessWidget {
  const _YearPicker({required this.years, required this.year, required this.onYear, required this.firstFocus});

  final List<int> years;
  final int? year;
  final ValueChanged<int?> onYear;
  final FocusNode firstFocus;

  @override
  Widget build(BuildContext context) {
    final options = <(int?, String)>[for (final y in years) (y, '$y'), (null, t.history.allTime)];
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: options.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final (value, label) = options[i];
          final selected = value == year;
          return Pressable(
            borderRadius: BorderRadius.circular(20),
            longPress: false,
            child: Material(
              color: selected ? _amber : Colors.white.withValues(alpha: 0.08),
              shape: const StadiumBorder(),
              child: InkWell(
                focusNode: i == 0 ? firstFocus : null,
                customBorder: const StadiumBorder(),
                focusColor: _amber.withValues(alpha: 0.45),
                onTap: () => onYear(value),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Center(
                    child: Text(
                      label.toUpperCase(),
                      style: TextStyle(
                        fontFamily: _display,
                        fontSize: 18,
                        letterSpacing: 1,
                        color: selected ? Colors.black : Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _StatsHero extends StatelessWidget {
  const _StatsHero({required this.stats, required this.wide});

  final HistoryStats stats;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final tiles = [
      _Stat(value: _grouped(stats.hours), label: t.history.hours, hero: true),
      _Stat(value: _grouped(stats.films), label: t.history.films),
      _Stat(value: _grouped(stats.episodes), label: t.history.episodes, sub: '${stats.shows} ${t.history.shows}'),
      _Stat(
        value: '${stats.currentStreak}',
        label: t.history.streak,
        sub: t.history.bestStreak(n: stats.bestStreak),
      ),
    ];
    final split = stats.minutes == 0 ? 0.0 : stats.filmMinutes / stats.minutes;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [_amber.withValues(alpha: 0.18), Colors.white.withValues(alpha: 0.03)],
        ),
        border: Border.all(color: _amber.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (wide)
            Row(children: [for (final tile in tiles) Expanded(child: tile)])
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                tiles.first,
                const SizedBox(height: 12),
                Row(children: [for (final tile in tiles.skip(1)) Expanded(child: tile)]),
              ],
            ),
          if (stats.minutes > 0) ...[
            const SizedBox(height: 18),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: SizedBox(
                height: 6,
                child: Row(
                  children: [
                    Expanded(
                      flex: math.max(1, (split * 1000).round()),
                      child: const ColoredBox(color: _amber, child: SizedBox.expand()),
                    ),
                    Expanded(
                      flex: math.max(1, ((1 - split) * 1000).round()),
                      child: ColoredBox(color: Colors.white.withValues(alpha: 0.25), child: const SizedBox.expand()),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Text(
                  '${t.history.films.toUpperCase()} ${stats.filmHours}H',
                  style: const TextStyle(fontFamily: _display, fontSize: 15, color: _amber, letterSpacing: 1),
                ),
                const Spacer(),
                Text(
                  'TV ${stats.tvHours}H',
                  style: const TextStyle(fontFamily: _display, fontSize: 15, color: Colors.white60, letterSpacing: 1),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  static String _grouped(int n) {
    final s = '$n';
    final out = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
      out.write(s[i]);
    }
    return out.toString();
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label, this.sub, this.hero = false});

  final String value;
  final String label;
  final String? sub;
  final bool hero;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            style: TextStyle(
              fontFamily: _display,
              fontSize: hero ? 64 : 40,
              height: 1,
              color: hero ? _amber : Colors.white,
            ),
          ),
        ),
        Text(
          label.toUpperCase(),
          style: const TextStyle(fontFamily: _display, fontSize: 15, letterSpacing: 1.2, color: Colors.white60),
        ),
        if (sub != null)
          Text(
            sub!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: Colors.white38),
          ),
      ],
    );
  }
}

/// One bar per month (a year), or per year (all time), amber by count.
class _MonthStrip extends StatelessWidget {
  const _MonthStrip({required this.stats, required this.year});

  final HistoryStats stats;
  final int? year;

  @override
  Widget build(BuildContext context) {
    final List<(String, int)> bars;
    if (year != null) {
      bars = [for (var m = 1; m <= 12; m++) (_monthName(m).substring(0, 1), stats.byMonth[DateTime(year!, m)] ?? 0)];
    } else {
      final perYear = <int, int>{};
      stats.byMonth.forEach((month, n) => perYear.update(month.year, (v) => v + n, ifAbsent: () => n));
      final first = perYear.keys.isEmpty ? DateTime.now().year : perYear.keys.reduce(math.min);
      final last = perYear.keys.isEmpty ? DateTime.now().year : perYear.keys.reduce(math.max);
      bars = [for (var y = first; y <= last; y++) ("'${'$y'.substring(2)}", perYear[y] ?? 0)];
    }
    final peak = bars.map((b) => b.$2).fold(0, math.max);
    return SizedBox(
      height: 96,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final (label, n) in bars)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (n > 0) Text('$n', style: const TextStyle(fontSize: 10, color: Colors.white54)),
                    const SizedBox(height: 2),
                    Container(
                      height: peak == 0 ? 2 : math.max(2, 56 * n / peak),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(3),
                        color: n == 0 ? Colors.white12 : Color.lerp(_amber.withValues(alpha: 0.35), _amber, n / peak),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      label,
                      maxLines: 1,
                      style: const TextStyle(fontFamily: _display, fontSize: 13, color: Colors.white54),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _PlayRow extends StatelessWidget {
  const _PlayRow({required this.play, required this.onOpen});

  final HistoryPlay play;
  final ValueChanged<HistoryPlay> onOpen;

  @override
  Widget build(BuildContext context) {
    final local = play.watchedAt.toLocal();
    final client = play.posterUrl == null && play.plexServerId != null
        ? context.read<MultiServerProvider>().getClientForServer(ServerId(play.plexServerId!))
        : null;
    final subtitle = play.isMovie
        ? [
            if (play.year != null) '${play.year}',
            if (play.runtimeMinutes != null) '${play.runtimeMinutes} min',
          ].join(' · ')
        : [
            if (play.season != null && play.episode != null)
              t.history.episodeLabel(season: play.season!, episode: play.episode!),
            ?play.episodeTitle,
          ].join(' · ');
    return Pressable(
      borderRadius: BorderRadius.circular(10),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          focusColor: _amber.withValues(alpha: 0.22),
          onTap: () => onOpen(play),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 44,
                  child: Column(
                    children: [
                      Text(
                        '${local.day}',
                        style: const TextStyle(fontFamily: _display, fontSize: 26, height: 1, color: Colors.white),
                      ),
                      Text(
                        _monthName(local.month).substring(0, 3).toUpperCase(),
                        style: const TextStyle(fontFamily: _display, fontSize: 12, color: Colors.white38),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: 44,
                    height: 66,
                    child: OptimizedMediaImage(
                      client: client,
                      imagePath: play.posterUrl ?? play.plexThumb,
                      width: 44,
                      height: 66,
                      fallbackIcon: play.isMovie ? Symbols.movie_rounded : Symbols.tv_rounded,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        play.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
                      ),
                      if (subtitle.isNotEmpty)
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white54, fontSize: 13),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _Sources(sources: play.sources),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Sources extends StatelessWidget {
  const _Sources({required this.sources});
  final Set<HistorySource> sources;

  @override
  Widget build(BuildContext context) {
    Widget badge(String text, Color color) => Container(
      margin: const EdgeInsets.only(left: 4),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(fontFamily: _display, fontSize: 12, color: color, letterSpacing: 1),
      ),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (sources.contains(HistorySource.plex)) badge('PLEX', _amber),
        if (sources.contains(HistorySource.trakt)) badge('TRAKT', Colors.white54),
      ],
    );
  }
}

class _Notes extends StatelessWidget {
  const _Notes({required this.state, required this.stats, required this.undated});

  final HistoryState state;
  final HistoryStats stats;
  final int undated;

  @override
  Widget build(BuildContext context) {
    final notes = [
      t.history.plexOnlyNote,
      if (stats.minutesEstimated > 0) t.history.estimatedNote(n: stats.minutesEstimated),
      if (stats.bulkCounted > 0) t.history.bulkNote(n: stats.bulkCounted),
      if (undated > 0) t.history.undatedNote(n: undated),
      if (!state.hasTrakt) t.history.noTraktNote,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final note in notes)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(note, style: const TextStyle(fontSize: 12, color: Colors.white38)),
          ),
      ],
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text, required this.busy, this.onRetry});

  final String text;
  final bool busy;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy) const CircularProgressIndicator(color: _amber),
          const SizedBox(height: 16),
          Text(text, style: const TextStyle(color: Colors.white70)),
          if (onRetry != null)
            TextButton(
              onPressed: onRetry,
              child: Text(t.history.retry, style: const TextStyle(color: _amber)),
            ),
        ],
      ),
    );
  }
}

/// The page's content column: full width up to 1100, centred beyond.
class _PageWidth extends StatelessWidget {
  const _PageWidth({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 1100),
    child: SizedBox(width: double.infinity, child: child),
  );
}
