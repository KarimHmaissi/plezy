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
import '../services/history/trakt_copy.dart';
import '../services/library_index/library_index.dart' show IndexSource, PlexIndexSource;
import '../services/plex_client.dart';
import '../theme/fork_motion.dart';
import '../theme/fork_spacing.dart';
import '../theme/mono_tokens.dart';
import '../utils/app_logger.dart';
import '../utils/catalog_navigation_helper.dart';
import '../utils/dialogs.dart';
import '../utils/snackbar_helper.dart';
import '../utils/media_navigation_helper.dart';
import '../utils/platform_detector.dart';
import '../widgets/app_icon.dart';
import '../widgets/desktop_app_bar.dart';
import '../widgets/focusable_tab_chip.dart';
import '../widgets/optimized_media_image.dart';
import '../widgets/pressable.dart';

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
    return ValueListenableBuilder<HistoryState>(
      valueListenable: _service.state,
      builder: (context, state, _) {
        final history = state.history;
        final years = history == null ? const <int>[] : HistoryStats.yearsOf(history.plays);
        if (!_yearChosen && years.isNotEmpty) _year = years.first;
        final trakt = _trakt;
        return Scaffold(
          body: RefreshIndicator(
            onRefresh: ForkMotion.refreshing(() => _load(force: true)),
            child: _HistoryBody(
              state: state,
              stats: history == null ? null : HistoryStats.compute(history.plays, year: _year),
              years: years,
              year: _year,
              firstFocus: _firstFocus,
              onRetry: () => _load(force: true),
              onYear: (y) {
                ForkMotion.selection();
                setState(() {
                  _yearChosen = true;
                  _year = y;
                });
              },
              onOpen: _open,
              traktCopy: trakt == null || history == null
                  ? null
                  : _TraktCopyBar(
                      history: history,
                      copier: TraktCopier(TraktClientHistoryWriter(trakt.client)),
                      onChanged: () => _load(force: true),
                    ),
            ),
          ),
        );
      },
    );
  }
}

/// Tests and previews: the page body for [state], without loading.
@visibleForTesting
Widget historyPreview(HistoryState state, {int? year}) => Scaffold(
  body: _HistoryBody(
    state: state,
    stats: HistoryStats.compute(state.history!.plays, year: year),
    years: HistoryStats.yearsOf(state.history!.plays),
    year: year,
    firstFocus: FocusNode(),
    onRetry: () {},
    onYear: (_) {},
    onOpen: (_) {},
  ),
);

/// Gutters and gaps: the shared touch rhythm, TV's wider shelf insets.
({double edge, double gap, double rowGap, double titleSize}) _rhythm(BuildContext context) {
  if (PlatformDetector.isTV()) return (edge: 48, gap: 14, rowGap: 32, titleSize: 26);
  final s = ForkSpacing.of(context);
  return (edge: s.edgeInset, gap: s.titleGap, rowGap: s.rowGap, titleSize: s.titleSize);
}

TextStyle? _sectionStyle(BuildContext context) =>
    Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700, fontSize: _rhythm(context).titleSize);

class _HistoryBody extends StatelessWidget {
  const _HistoryBody({
    required this.state,
    required this.stats,
    required this.years,
    required this.year,
    required this.firstFocus,
    required this.onRetry,
    required this.onYear,
    required this.onOpen,
    this.traktCopy,
  });

  final HistoryState state;

  /// Null until the first load lands.
  final HistoryStats? stats;
  final List<int> years;
  final int? year;
  final FocusNode firstFocus;
  final VoidCallback onRetry;
  final ValueChanged<int?> onYear;
  final ValueChanged<HistoryPlay> onOpen;

  /// "Send Plex watches to Trakt", when Trakt is connected.
  final Widget? traktCopy;

  @override
  Widget build(BuildContext context) {
    final r = _rhythm(context);
    final stats = this.stats;
    final history = state.history;
    final textTheme = Theme.of(context).textTheme;
    final tk = tokens(context);

    Widget boxed(Widget child, {double top = 0}) => SliverPadding(
      padding: EdgeInsets.fromLTRB(r.edge, top, r.edge, 0),
      sliver: SliverToBoxAdapter(
        child: Align(
          alignment: Alignment.topCenter,
          child: _PageWidth(child: child),
        ),
      ),
    );

    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        DesktopSliverAppBar(
          title: Text(t.history.title),
          pinned: false,
          floating: true,
          snap: true,
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          surfaceTintColor: Colors.transparent,
          shadowColor: Colors.transparent,
          scrolledUnderElevation: 0,
          actions: [
            if (state.loading)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: tk.textMuted),
                ),
              ),
          ],
        ),
        if (history == null || stats == null)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _Message(
              text: state.error == null ? t.history.loading : t.history.failed,
              busy: state.error == null,
              onRetry: state.error != null ? onRetry : null,
            ),
          )
        else ...[
          boxed(_YearPicker(years: years, year: year, onYear: onYear, firstFocus: firstFocus), top: 4),
          boxed(_StatsHero(stats: stats), top: r.gap + 6),
          if (traktCopy != null) boxed(traktCopy!, top: 12),
          if (stats.byMonth.isNotEmpty) ...[
            boxed(Text(t.history.byMonth, style: _sectionStyle(context)), top: r.rowGap),
            boxed(
              _MonthStrip(stats: stats, year: year),
              top: r.gap,
            ),
          ],
          for (final section in _insightSections(context, stats, onOpen)) ...[
            boxed(Text(section.title, style: _sectionStyle(context)), top: r.rowGap),
            boxed(section.child, top: r.gap),
          ],
          boxed(Text(t.history.timeline, style: _sectionStyle(context)), top: r.rowGap),
          if (stats.plays.isEmpty)
            boxed(
              Text(t.history.empty, style: textTheme.bodyMedium?.copyWith(color: tk.textMuted)),
              top: r.gap,
            ),
          for (final group in _byMonth(stats.plays)) ...[
            boxed(
              Text(
                '${_monthName(group.month.month)} ${group.month.year}',
                style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700, color: tk.textMuted),
              ),
              top: r.gap + 8,
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(r.edge, 6, r.edge, 0),
              sliver: SliverList.builder(
                itemCount: group.plays.length,
                itemBuilder: (context, i) => Align(
                  alignment: Alignment.topCenter,
                  child: _PageWidth(
                    child: _PlayRow(play: group.plays[i], onOpen: onOpen),
                  ),
                ),
              ),
            ),
          ],
          SliverPadding(
            padding: EdgeInsets.fromLTRB(r.edge, r.rowGap, r.edge, 48),
            sliver: SliverToBoxAdapter(
              child: Align(
                alignment: Alignment.topCenter,
                child: _PageWidth(
                  child: _Notes(state: state, stats: stats, undated: history.undated),
                ),
              ),
            ),
          ),
        ],
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

class _YearPicker extends StatelessWidget {
  const _YearPicker({required this.years, required this.year, required this.onYear, required this.firstFocus});

  final List<int> years;
  final int? year;
  final ValueChanged<int?> onYear;
  final FocusNode firstFocus;

  @override
  Widget build(BuildContext context) {
    final options = <(int?, String)>[for (final y in years) (y, '$y'), (null, t.history.allTime)];
    final selected = options.indexWhere((o) => o.$1 == year);
    void step(int delta) {
      final i = selected + delta;
      if (i >= 0 && i < options.length) onYear(options[i].$1);
    }

    return Align(
      alignment: Alignment.centerLeft,
      child: TabChipStrip(
        children: [
          for (final (i, (value, label)) in options.indexed)
            FocusableTabChip(
              label: label,
              isSelected: value == year,
              focusNode: i == 0 ? firstFocus : null,
              onSelect: () => onYear(value),
              onNavigateLeft: () => step(-1),
              onNavigateRight: () => step(1),
            ),
        ],
      ),
    );
  }
}

class _StatsHero extends StatelessWidget {
  const _StatsHero({required this.stats});

  final HistoryStats stats;

  @override
  Widget build(BuildContext context) {
    final tk = tokens(context);
    final textTheme = Theme.of(context).textTheme;
    final wide = MediaQuery.sizeOf(context).width >= 600;
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
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
                  const SizedBox(height: 14),
                  Row(children: [for (final tile in tiles.skip(1)) Expanded(child: tile)]),
                ],
              ),
            if (stats.minutes > 0) ...[
              const SizedBox(height: 18),
              ClipRRect(
                borderRadius: BorderRadius.circular(tk.radiusXs),
                child: SizedBox(
                  height: 6,
                  child: Row(
                    children: [
                      Expanded(
                        flex: math.max(1, (split * 1000).round()),
                        child: ColoredBox(color: tk.accent, child: const SizedBox.expand()),
                      ),
                      Expanded(
                        flex: math.max(1, ((1 - split) * 1000).round()),
                        child: ColoredBox(color: tk.text.withValues(alpha: 0.18), child: const SizedBox.expand()),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Text(
                    '${t.history.films} · ${stats.filmHours} h',
                    style: textTheme.bodySmall?.copyWith(color: tk.text),
                  ),
                  const Spacer(),
                  Text('TV · ${stats.tvHours} h', style: textTheme.bodySmall),
                ],
              ),
            ],
          ],
        ),
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
    final textTheme = Theme.of(context).textTheme;
    final tk = tokens(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            style: (hero ? textTheme.displaySmall : textTheme.headlineSmall)?.copyWith(
              fontWeight: FontWeight.w700,
              color: hero ? tk.accent : tk.text,
              height: 1.1,
            ),
          ),
        ),
        Text(label, style: textTheme.labelLarge?.copyWith(color: tk.textMuted)),
        if (sub != null) Text(sub!, maxLines: 1, overflow: TextOverflow.ellipsis, style: textTheme.bodySmall),
      ],
    );
  }
}

/// One bar per month (a year), or per year (all time), by count.
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
    return _Bars(bars: bars, height: 96);
  }
}

/// Vertical bars with a count above and a label below.
class _Bars extends StatelessWidget {
  const _Bars({required this.bars, required this.height});

  final List<(String, int)> bars;
  final double height;

  @override
  Widget build(BuildContext context) {
    final tk = tokens(context);
    final small = Theme.of(context).textTheme.labelSmall?.copyWith(color: tk.textMuted);
    final peak = bars.map((b) => b.$2).fold(0, math.max);
    return SizedBox(
      height: height,
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
                    if (n > 0) Text('$n', maxLines: 1, style: small),
                    const SizedBox(height: 2),
                    Container(
                      height: peak == 0 ? 2 : math.max(2, (height - 40) * n / peak),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(tk.radiusXs),
                        color: n == 0
                            ? tk.text.withValues(alpha: 0.08)
                            : tk.accent.withValues(alpha: 0.35 + 0.65 * n / peak),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(label, maxLines: 1, style: small),
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
    final tk = tokens(context);
    final textTheme = Theme.of(context).textTheme;
    final local = play.watchedAt.toLocal();
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
      borderRadius: BorderRadius.circular(tk.radiusMd),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(tk.radiusMd),
          onTap: () => onOpen(play),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 40,
                  child: Column(
                    children: [
                      Text(
                        '${local.day}',
                        style: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700, height: 1),
                      ),
                      Text(
                        _monthName(local.month).substring(0, 3),
                        style: textTheme.labelSmall?.copyWith(color: tk.textMuted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                _Poster(play: play, width: 44),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        play.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      if (subtitle.isNotEmpty)
                        Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: textTheme.bodySmall),
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
    final tk = tokens(context);
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(color: tk.textMuted);
    Widget badge(String text) => Container(
      margin: const EdgeInsets.only(left: 4),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: tk.text.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(tk.radiusXs),
      ),
      child: Text(text, style: style),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (sources.contains(HistorySource.plex)) badge('Plex'),
        if (sources.contains(HistorySource.trakt)) badge('Trakt'),
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
    final style = Theme.of(context).textTheme.bodySmall;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final note in notes)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(note, style: style),
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
          if (busy) const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(text, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens(context).textMuted)),
          if (onRetry != null) TextButton(onPressed: onRetry, child: Text(t.history.retry)),
        ],
      ),
    );
  }
}

/// A title's poster: Trakt's when known, else Plex's from its server.
class _Poster extends StatelessWidget {
  const _Poster({required this.play, required this.width});

  final HistoryPlay play;
  final double width;

  @override
  Widget build(BuildContext context) {
    final height = width * 1.5;
    final client = play.posterUrl == null && play.plexServerId != null
        ? context.read<MultiServerProvider>().getClientForServer(ServerId(play.plexServerId!))
        : null;
    return ClipRRect(
      borderRadius: BorderRadius.circular(width < 50 ? tokens(context).radiusSm : tokens(context).radiusMd),
      child: SizedBox(
        width: width,
        height: height,
        child: OptimizedMediaImage(
          client: client,
          imagePath: play.posterUrl ?? play.plexThumb,
          width: width,
          height: height,
          fallbackIcon: play.isMovie ? Symbols.movie_rounded : Symbols.tv_rounded,
        ),
      ),
    );
  }
}

/// The sections between the month strip and the timeline: the longest
/// binge, top genres, directors and actors, rewatches and decades.
List<({String title, Widget child})> _insightSections(
  BuildContext context,
  HistoryStats stats,
  ValueChanged<HistoryPlay> onOpen,
) {
  List<HistoryPlay> titlesWith(bool Function(HistoryPlay p) test) {
    final seen = <String>{};
    return [
      for (final p in stats.counted)
        if (test(p) && seen.add(p.titleKey) && (p.posterUrl != null || p.plexThumb != null)) p,
    ];
  }

  final binge = stats.longestBinge;
  return [
    if (binge != null) (title: t.history.longestBinge, child: _BingeCard(binge: binge, onOpen: onOpen)),
    if (stats.topGenres.isNotEmpty)
      (title: t.history.topGenres, child: _RankedBars(entries: stats.topGenres.take(6).toList())),
    if (stats.topDirectors.isNotEmpty)
      (
        title: t.history.directors,
        child: _PeopleRow(
          entries: stats.topDirectors.take(8).toList(),
          postersFor: (name) => titlesWith((p) => p.directors.contains(name)),
          onOpen: onOpen,
        ),
      ),
    if (stats.topCast.isNotEmpty)
      (
        title: t.history.actors,
        child: _PeopleRow(
          entries: stats.topCast.take(8).toList(),
          postersFor: (name) => titlesWith((p) => p.cast.contains(name)),
          onOpen: onOpen,
        ),
      ),
    if (stats.rewatches.isNotEmpty)
      (title: t.history.rewatches, child: _RewatchRow(rewatches: stats.rewatches, onOpen: onOpen)),
    if (stats.decades.length > 1)
      (
        title: t.history.decades,
        child: _Bars(
          bars: [for (final e in stats.decades.entries) ("'${'${e.key}'.substring(2)}s", e.value)],
          height: 90,
        ),
      ),
  ];
}

class _BingeCard extends StatelessWidget {
  const _BingeCard({required this.binge, required this.onOpen});

  final ({HistoryPlay play, int episodes}) binge;
  final ValueChanged<HistoryPlay> onOpen;

  @override
  Widget build(BuildContext context) {
    final tk = tokens(context);
    final textTheme = Theme.of(context).textTheme;
    final local = binge.play.watchedAt.toLocal();
    return Pressable(
      borderRadius: BorderRadius.circular(14),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => onOpen(binge.play),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                _Poster(play: binge.play, width: 64),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${binge.episodes}',
                        style: textTheme.displaySmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: tk.accent,
                          height: 1.1,
                        ),
                      ),
                      Text(t.history.bingeLine(n: binge.episodes), style: textTheme.titleSmall),
                      const SizedBox(height: 4),
                      Text(
                        '${binge.play.title} · ${local.day} ${_monthName(local.month)} ${local.year}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Names with a bar each, longest first.
class _RankedBars extends StatelessWidget {
  const _RankedBars({required this.entries});

  final List<MapEntry<String, int>> entries;

  @override
  Widget build(BuildContext context) {
    final tk = tokens(context);
    final textTheme = Theme.of(context).textTheme;
    final peak = entries.first.value;
    return Column(
      children: [
        for (final e in entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 120,
                  child: Text(e.key, maxLines: 1, overflow: TextOverflow.ellipsis, style: textTheme.bodyMedium),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, c) => Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        height: 8,
                        width: math.max(4, c.maxWidth * e.value / peak),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(tk.radiusXs),
                          color: tk.accent.withValues(alpha: 0.35 + 0.65 * e.value / peak),
                        ),
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  width: 44,
                  child: Text('${e.value}', textAlign: TextAlign.right, style: textTheme.bodySmall),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// People as cards: a fanned stack of their posters, name and count.
class _PeopleRow extends StatelessWidget {
  const _PeopleRow({required this.entries, required this.postersFor, required this.onOpen});

  final List<MapEntry<String, int>> entries;
  final List<HistoryPlay> Function(String name) postersFor;
  final ValueChanged<HistoryPlay> onOpen;

  @override
  Widget build(BuildContext context) {
    final tk = tokens(context);
    final textTheme = Theme.of(context).textTheme;
    return SizedBox(
      height: 172,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        itemCount: entries.length,
        separatorBuilder: (_, _) => SizedBox(width: ForkSpacing.of(context).cardGap),
        itemBuilder: (context, i) {
          final e = entries[i];
          final posters = postersFor(e.key).take(3).toList();
          return SizedBox(
            width: 112,
            child: Pressable(
              borderRadius: BorderRadius.circular(tk.radiusMd),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(tk.radiusMd),
                  onTap: posters.isEmpty ? null : () => onOpen(posters.first),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        height: 110,
                        width: 112,
                        child: Stack(
                          children: [
                            for (final (j, p) in posters.indexed.toList().reversed)
                              Positioned(
                                left: j * 22.0,
                                top: j * 6.0,
                                child: Transform.rotate(
                                  angle: (j - 1) * 0.06,
                                  child: _Poster(play: p, width: 66),
                                ),
                              ),
                            if (posters.isEmpty)
                              Center(child: Icon(Symbols.person_rounded, color: tk.textMuted, size: 40)),
                          ],
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        e.key,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600, height: 1.2),
                      ),
                      Text(t.history.watchCount(n: e.value), style: textTheme.bodySmall),
                    ],
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

class _RewatchRow extends StatelessWidget {
  const _RewatchRow({required this.rewatches, required this.onOpen});

  final List<MapEntry<HistoryPlay, int>> rewatches;
  final ValueChanged<HistoryPlay> onOpen;

  @override
  Widget build(BuildContext context) {
    final tk = tokens(context);
    final scheme = Theme.of(context).colorScheme;
    final films = rewatches.take(12).toList();
    return SizedBox(
      height: 132,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        itemCount: films.length,
        separatorBuilder: (_, _) => SizedBox(width: ForkSpacing.of(context).cardGap),
        itemBuilder: (context, i) {
          final e = films[i];
          return Pressable(
            borderRadius: BorderRadius.circular(tk.radiusMd),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(tk.radiusMd),
                onTap: () => onOpen(e.key),
                child: Stack(
                  children: [
                    _Poster(play: e.key, width: 84),
                    Positioned(
                      right: 4,
                      bottom: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: scheme.primary,
                          borderRadius: BorderRadius.circular(tk.radiusXs),
                        ),
                        child: Text(
                          t.history.timesWatched(n: e.value),
                          style: Theme.of(
                            context,
                          ).textTheme.labelMedium?.copyWith(color: scheme.onPrimary, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// "Send Plex watches to Trakt" (with its preview) and "Undo last send".
class _TraktCopyBar extends StatefulWidget {
  const _TraktCopyBar({required this.history, required this.copier, required this.onChanged});

  final MergedHistory history;
  final TraktCopier copier;
  final VoidCallback onChanged;

  @override
  State<_TraktCopyBar> createState() => _TraktCopyBarState();
}

class _TraktCopyBarState extends State<_TraktCopyBar> {
  TraktSendRecord? _last;

  @override
  void initState() {
    super.initState();
    unawaited(_readLast());
  }

  Future<void> _readLast() async {
    final last = await widget.copier.lastSend();
    if (mounted) setState(() => _last = last);
  }

  Future<void> _preview() async {
    ForkMotion.selection();
    final plan = planTraktCopy(widget.history);
    final sent = await showModalBottomSheet<TraktSendRecord>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _TraktCopySheet(plan: plan, copier: widget.copier),
    );
    if (sent == null || !mounted) return;
    setState(() => _last = sent);
    showSuccessSnackBar(context, t.history.copy.done(films: sent.films, episodes: sent.episodes));
    widget.onChanged();
  }

  Future<void> _undo() async {
    final last = _last;
    if (last == null) return;
    final ok = await showConfirmDialog(
      context,
      title: t.history.copy.undoTitle,
      message: t.history.copy.undoMessage(n: last.historyIds.length),
      confirmText: t.history.copy.undoConfirm,
      isDestructive: true,
    );
    if (!ok || !mounted) return;
    try {
      final removed = await widget.copier.undoLastSend();
      if (!mounted) return;
      setState(() => _last = null);
      showSuccessSnackBar(context, t.history.copy.undone(n: removed));
      widget.onChanged();
    } catch (e) {
      appLogger.w('History copy: undo failed', error: e);
      if (mounted) showErrorSnackBar(context, t.history.copy.failed);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        Pressable(
          longPress: false,
          borderRadius: BorderRadius.circular(MonoTokens.radiusFull),
          child: OutlinedButton.icon(
            onPressed: _preview,
            icon: const AppIcon(Symbols.cloud_upload_rounded, size: 18),
            label: Text(t.history.copy.button),
          ),
        ),
        if (_last != null)
          Pressable(
            longPress: false,
            borderRadius: BorderRadius.circular(MonoTokens.radiusFull),
            child: TextButton.icon(
              onPressed: _undo,
              icon: const AppIcon(Symbols.undo_rounded, size: 18),
              label: Text(t.history.copy.undoButton),
            ),
          ),
      ],
    );
  }
}

/// The preview: what would be sent and what's skipped; nothing is written
/// until Confirm.
class _TraktCopySheet extends StatefulWidget {
  const _TraktCopySheet({required this.plan, required this.copier});

  final TraktCopyPlan plan;
  final TraktCopier copier;

  @override
  State<_TraktCopySheet> createState() => _TraktCopySheetState();
}

class _TraktCopySheetState extends State<_TraktCopySheet> {
  (int, int)? _progress;
  String? _error;

  Future<void> _send() async {
    ForkMotion.selection();
    setState(() {
      _progress = (0, 1);
      _error = null;
    });
    try {
      final record = await widget.copier.send(
        widget.plan,
        onProgress: (done, total) {
          if (mounted) setState(() => _progress = (done, total));
        },
      );
      ForkMotion.success();
      if (mounted) Navigator.pop(context, record);
    } catch (e) {
      appLogger.w('History copy: send failed', error: e);
      if (mounted) {
        setState(() {
          _progress = null;
          _error = t.history.copy.failed;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final plan = widget.plan;
    final textTheme = Theme.of(context).textTheme;
    final tk = tokens(context);
    final label = textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700);
    final body = textTheme.bodyMedium;
    final sending = _progress != null;
    Widget gap([double h = 14]) => SizedBox(height: h);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(t.history.copy.title, style: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
              gap(8),
              Text(
                plan.toSend.isEmpty
                    ? t.history.copy.nothing
                    : t.history.copy.adds(films: plan.films, episodes: plan.episodes),
                style: textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600, color: tk.accent),
              ),
              if (plan.toSend.isNotEmpty) ...[
                gap(),
                Text(t.history.copy.byYear, style: label),
                for (final e in plan.byYear.entries)
                  Text(
                    '${e.key}: ${t.history.copy.yearLine(films: e.value.films, episodes: e.value.episodes)}',
                    style: body,
                  ),
                gap(),
                Text(t.history.copy.sample, style: label),
                for (final p in plan.toSend.take(8))
                  Text(
                    [
                      p.title,
                      if (!p.isMovie && p.season != null && p.episode != null)
                        t.history.episodeLabel(season: p.season!, episode: p.episode!),
                      _shortDate(p.watchedAt),
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: body,
                  ),
              ],
              gap(),
              Text(t.history.copy.skipped, style: label),
              Text(t.history.copy.alreadyOnTrakt(n: plan.alreadyOnTrakt), style: body),
              if (plan.bulkDates > 0) Text(t.history.copy.bulk(n: plan.bulkDates), style: body),
              if (plan.noIds > 0) Text(t.history.copy.noIds(n: plan.noIds), style: body),
              gap(),
              Text(t.history.copy.howItWorks, style: textTheme.bodySmall),
              if (_error != null) ...[
                gap(10),
                Text(_error!, style: body?.copyWith(color: Theme.of(context).colorScheme.error)),
              ],
              gap(18),
              if (sending)
                Row(
                  children: [
                    const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 12),
                    Text(
                      t.history.copy.sending(done: _progress!.$1, total: _progress!.$2),
                      style: body,
                    ),
                  ],
                )
              else
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(onPressed: () => Navigator.pop(context), child: Text(t.history.copy.cancel)),
                    const SizedBox(width: 8),
                    if (plan.toSend.isNotEmpty) FilledButton(onPressed: _send, child: Text(t.history.copy.confirm)),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  static String _shortDate(DateTime at) {
    final l = at.toLocal();
    return '${l.day} ${_monthName(l.month).substring(0, 3)} ${l.year}';
  }
}
