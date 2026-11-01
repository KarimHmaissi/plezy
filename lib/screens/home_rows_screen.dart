import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../i18n/strings.g.dart';
import '../models/trakt/trakt_user_list.dart';
import '../providers/catalog_sources_provider.dart';
import '../providers/discover_provider.dart';
import '../providers/explore_provider.dart';
import '../services/catalog/home_pins.dart';
import '../services/catalog/home_rows.dart';
import '../services/catalog/trakt_lists_catalog_source.dart';
import '../utils/app_logger.dart';
import '../utils/snackbar_helper.dart';
import '../widgets/app_icon.dart';
import '../widgets/app_menu.dart';
import '../widgets/focusable_list_tile.dart';
import '../widgets/focused_scroll_scaffold.dart';
import '../widgets/home_row_actions.dart';

enum _RowAction { top, up, down, remove }

/// The Home builder: the rows on Home in order (move up/down, remove), then
/// every row that can be added, grouped by where it comes from. Rows found
/// elsewhere (an Explore shelf, a library row, a Watchlist shelf, a
/// collection) are added from their own hold-OK menu.
class HomeRowsScreen extends StatefulWidget {
  final TraktListsCatalogSource source;

  const HomeRowsScreen({super.key, required this.source});

  @override
  State<HomeRowsScreen> createState() => _HomeRowsScreenState();
}

class _HomeRowsScreenState extends State<HomeRowsScreen> {
  List<TraktUserList>? _lists;

  HomePinsController get _pins => widget.source.pins;

  @override
  void initState() {
    super.initState();
    unawaited(_pins.ensureLoaded(refresh: true));
    unawaited(_loadLists());
  }

  Future<void> _loadLists() async {
    final lists = await widget.source.listsForRows();
    if (mounted) setState(() => _lists = lists);
  }

  Future<void> _run(Future<void> Function() change) async {
    try {
      await change();
    } catch (e) {
      appLogger.w('Home rows: save failed', error: e);
      if (mounted) showErrorSnackBar(context, homeRowsSaveError(e));
    }
  }

  Future<void> _rowMenu(BuildContext tileContext, HomeRowEntry row, int index, int count) async {
    final box = tileContext.findRenderObject() as RenderBox?;
    final action = await showAdaptiveAppMenu<_RowAction>(
      context,
      title: row.title,
      anchorRect: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
      focusFirstItem: true,
      entries: [
        if (index > 0) ...[
          AppMenuItem(value: _RowAction.up, label: t.homeRows.moveUp, icon: Symbols.arrow_upward_rounded),
          if (index > 1)
            AppMenuItem(value: _RowAction.top, label: t.homeRows.moveToTop, icon: Symbols.vertical_align_top_rounded),
        ],
        if (index < count - 1)
          AppMenuItem(value: _RowAction.down, label: t.homeRows.moveDown, icon: Symbols.arrow_downward_rounded),
        AppMenuItem(
          value: _RowAction.remove,
          label: t.homeRows.removeFromHome,
          icon: Symbols.remove_circle_rounded,
          destructive: true,
        ),
      ],
    );
    if (action == null || !mounted) return;
    switch (action) {
      case _RowAction.up:
        await _run(() => _pins.move(row.id, -1));
      case _RowAction.top:
        await _run(() => _pins.move(row.id, -index));
      case _RowAction.down:
        await _run(() => _pins.move(row.id, 1));
      case _RowAction.remove:
        await removeHomeRow(context, row, announce: false);
    }
  }

  Widget _section(String title, {String? subtitle}) => ListTile(
    title: Text(title, style: Theme.of(context).textTheme.titleMedium),
    subtitle: subtitle == null ? null : Text(subtitle),
  );

  Widget _addSwitch(HomeRowEntry row, {IconData icon = Symbols.view_carousel_rounded}) {
    final onHome = _pins.contains(row.id);
    return FocusableSwitchListTile(
      secondary: AppIcon(icon, fill: 1),
      title: Text(row.title),
      value: onHome,
      onChanged: (add) => unawaited(add ? _run(() => _pins.add([row])) : removeHomeRow(context, row, announce: false)),
    );
  }

  /// One switch for a whole group (all "Recently added" rows).
  Widget _groupSwitch(String title, List<HomeRowEntry> rows) {
    final added = rows.where((r) => _pins.contains(r.id)).length;
    return FocusableSwitchListTile(
      secondary: const AppIcon(Symbols.library_add_rounded, fill: 1),
      title: Text(title),
      subtitle: Text(t.homeRows.groupCount(added: added, count: rows.length)),
      value: added == rows.length,
      onChanged: (add) => unawaited(_run(() => add ? _pins.add(rows) : _pins.remove(rows.map((r) => r.id)))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sources = Provider.of<CatalogSourcesProvider?>(context, listen: false);
    final discover = Provider.of<DiscoverProvider?>(context, listen: false);
    return ListenableBuilder(
      listenable: Listenable.merge([_pins, homeRowLoadStates]),
      builder: (context, _) {
        final rows = _pins.rows;
        final plex = mergePlexHubs(discover?.hubs ?? const []);
        final plexRows = [for (final row in plex) (id: row.rowId, title: row.hub.title, sources: row.sources)];
        final recentlyAdded = [
          for (final row in plexRows)
            if (normalizeRowTitle(row.title).startsWith('recently added')) row,
        ];
        final lists = _lists;
        final exploreRows = [
          for (final source in sources?.connectedSources ?? const [])
            if (source is! TraktListsCatalogSource)
              for (final row in source.supportedRows)
                (
                  id: HomeRowIds.catalogRow(source.id, row),
                  title: '${ExploreProvider.rowTitle(row)} · ${source.displayName}',
                  sources: const <String>[],
                ),
        ];
        return FocusedScrollScaffold(
          title: Text(t.homeRows.title),
          slivers: [
            SliverList.list(
              children: [
                FocusableSwitchListTile(
                  autofocus: true,
                  secondary: const AppIcon(Symbols.dashboard_customize_rounded, fill: 1),
                  title: Text(t.homeRows.onlyAddedRows),
                  subtitle: Text(t.homeRows.onlyAddedRowsDescription),
                  value: _pins.curated,
                  onChanged: (curated) => unawaited(_run(() => _pins.setCurated(curated))),
                ),
                _section(t.homeRows.onHomeSection, subtitle: t.homeRows.onHomeSectionDescription),
                if (rows.isEmpty) ListTile(subtitle: Text(t.homeRows.nothingOnHome)),
                for (final (i, row) in rows.indexed)
                  Builder(
                    builder: (tileContext) => FocusableListTile(
                      leading: Text('${i + 1}', style: Theme.of(context).textTheme.titleMedium),
                      title: Text(row.title),
                      subtitle: switch (homeRowLoadStates.value[row.id]) {
                        HomeRowLoadState.loading => Text(t.homeRows.rowLoading),
                        HomeRowLoadState.empty => Text(t.homeRows.rowEmpty),
                        HomeRowLoadState.unavailable => Text(t.homeRows.rowUnavailable),
                        _ => null,
                      },
                      trailing: const AppIcon(Symbols.more_vert_rounded),
                      onTap: () => unawaited(_rowMenu(tileContext, row, i, rows.length)),
                    ),
                  ),
                const Divider(),
                _section(t.homeRows.addRowsSection, subtitle: t.homeRows.addRowsSectionDescription),
                _section(t.homeRows.continueWatchingSection),
                _addSwitch((
                  id: HomeRowIds.continueWatching,
                  title: t.discover.continueWatching,
                  sources: const [],
                ), icon: Symbols.play_circle_rounded),
                _addSwitch((
                  id: HomeRowIds.pickBackUp,
                  title: t.discover.pickBackUp,
                  sources: const [],
                ), icon: Symbols.history_rounded),
                if (plexRows.isNotEmpty) ...[
                  _section(t.homeRows.plexSection),
                  if (recentlyAdded.length > 1) _groupSwitch(t.homeRows.allRecentlyAdded, recentlyAdded),
                  for (final row in plexRows) _addSwitch(row),
                ],
                _section(t.homeRows.chartsSection),
                for (final chart in TraktListsCatalogSource.charts)
                  _addSwitch((
                    id: HomeRowIds.traktLists(chart.id),
                    title: chart.title,
                    sources: const [],
                  ), icon: Symbols.trending_up_rounded),
                _section(t.homeRows.listsSection),
                if (lists == null)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else
                  for (final list in lists)
                    _addSwitch((
                      id: HomeRowIds.traktLists(TraktListsCatalogSource.listHubId(list)),
                      title: list.name,
                      sources: const [],
                    ), icon: Symbols.format_list_bulleted_rounded),
                _section(t.homeRows.watchlistSection),
                _addSwitch((
                  id: HomeRowIds.watchlist('films'),
                  title: t.watchlist.films,
                  sources: const [],
                ), icon: Symbols.bookmark_rounded),
                _addSwitch((
                  id: HomeRowIds.watchlist('tv'),
                  title: t.watchlist.tv,
                  sources: const [],
                ), icon: Symbols.bookmark_rounded),
                _addSwitch((
                  id: HomeRowIds.comfort,
                  title: t.homeRows.comfortRow,
                  sources: const [],
                ), icon: Symbols.weekend_rounded),
                if (exploreRows.isNotEmpty) ...[
                  _section(t.homeRows.exploreSection),
                  for (final row in exploreRows) _addSwitch(row, icon: Symbols.explore_rounded),
                ],
                ListTile(subtitle: Text(t.homeRows.syncedNote)),
              ],
            ),
          ],
        );
      },
    );
  }
}
