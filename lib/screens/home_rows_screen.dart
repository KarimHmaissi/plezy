import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../i18n/strings.g.dart';
import '../models/trakt/trakt_user_list.dart';
import '../services/catalog/home_pins.dart';
import '../services/catalog/trakt_lists_catalog_source.dart';
import '../utils/app_logger.dart';
import '../utils/snackbar_helper.dart';
import '../widgets/app_icon.dart';
import '../widgets/focusable_list_tile.dart';
import '../widgets/focused_scroll_scaffold.dart';

/// User-facing message for a failed Home rows save.
String homeRowsSaveError(Object e) =>
    e is HomePinsListLimitException ? t.homeRows.listLimitReached(limit: e.limit) : t.homeRows.saveFailed;

/// Pin and unpin rows on Home, and bring back rows removed from it. Rows
/// are pinned with switches: what's pinned (in pin order), the Trakt charts,
/// then the user's liked and own Trakt lists; hidden rows are listed last.
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

  Future<void> _setPinned(String id, String title, bool pinned) async {
    try {
      await _pins.setPinned(id, title, pinned);
    } catch (e) {
      appLogger.w('Home rows: pin failed', error: e);
      if (mounted) showErrorSnackBar(context, homeRowsSaveError(e));
    }
  }

  Future<void> _restore(HomeRow row) async {
    try {
      await _pins.setHidden(row.id, row.title, false);
      if (mounted) showSuccessSnackBar(context, t.homeRows.restored(title: row.title));
    } catch (e) {
      appLogger.w('Home rows: restore failed', error: e);
      if (mounted) showErrorSnackBar(context, homeRowsSaveError(e));
    }
  }

  Widget _section(String title) => ListTile(title: Text(title, style: Theme.of(context).textTheme.titleMedium));

  Widget _pinSwitch(
    String id,
    String title, {
    IconData icon = Symbols.format_list_bulleted_rounded,
    bool autofocus = false,
  }) => FocusableSwitchListTile(
    autofocus: autofocus,
    secondary: AppIcon(_pins.isPinned(id) ? Symbols.keep_rounded : icon, fill: 1),
    title: Text(title),
    value: _pins.isPinned(id),
    onChanged: (pinned) => unawaited(_setPinned(id, title, pinned)),
  );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _pins,
      builder: (context, _) {
        final hidden = _pins.hidden;
        final lists = _lists;
        // Switches stay where they are when toggled; "Pinned to Home" only
        // lists pins found nowhere below (e.g. a public list pinned from
        // Discover lists).
        final shownBelow = [
          for (final chart in TraktListsCatalogSource.charts) chart.id,
          for (final list in lists ?? const <TraktUserList>[]) TraktListsCatalogSource.listHubId(list),
        ];
        final pinned = [
          for (final pin in _pins.pins)
            if (lists != null && !shownBelow.any((id) => samePinnedRow(id, pin.id))) pin,
        ];
        return FocusedScrollScaffold(
          title: Text(t.homeRows.title),
          slivers: [
            SliverList.list(
              children: [
                ListTile(subtitle: Text(t.homeRows.syncedNote)),
                if (pinned.isNotEmpty) ...[
                  _section(t.homeRows.pinnedSection),
                  for (final (i, pin) in pinned.indexed) _pinSwitch(pin.id, pin.title, autofocus: i == 0),
                ],
                _section(t.homeRows.chartsSection),
                for (final (i, chart) in TraktListsCatalogSource.charts.indexed)
                  _pinSwitch(
                    chart.id,
                    chart.title,
                    icon: Symbols.trending_up_rounded,
                    autofocus: pinned.isEmpty && i == 0,
                  ),
                _section(t.homeRows.listsSection),
                if (lists == null)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else
                  for (final list in lists) _pinSwitch(TraktListsCatalogSource.listHubId(list), list.name),
                _section(t.homeRows.hiddenSection),
                if (hidden.isEmpty)
                  ListTile(subtitle: Text(t.homeRows.noHiddenRows))
                else
                  for (final row in hidden.reversed)
                    FocusableListTile(
                      leading: const AppIcon(Symbols.visibility_rounded, fill: 1),
                      title: Text(row.title),
                      subtitle: Text(t.homeRows.restore),
                      onTap: () => unawaited(_restore(row)),
                    ),
              ],
            ),
          ],
        );
      },
    );
  }
}
