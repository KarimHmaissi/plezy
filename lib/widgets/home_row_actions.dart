import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../i18n/strings.g.dart';
import '../providers/catalog_sources_provider.dart';
import '../screens/home_rows_screen.dart';
import '../services/catalog/home_pins.dart';
import '../services/catalog/trakt_lists_catalog_source.dart';
import '../utils/app_logger.dart';
import '../utils/dialogs.dart';
import '../utils/snackbar_helper.dart';
import 'media_context_menu.dart' show MediaMenuExtraEntry;

/// The Trakt Lists source, which owns the Home layout (it's stored on
/// Trakt), or null when Trakt isn't connected.
TraktListsCatalogSource? homeLayoutSourceOf(BuildContext context) => Provider.of<CatalogSourcesProvider?>(
  context,
  listen: false,
)?.connectedSources.whereType<TraktListsCatalogSource>().firstOrNull;

/// User-facing message for a failed Home layout save.
String homeRowsSaveError(Object e) =>
    e is HomePinsListLimitException ? t.homeRows.listLimitReached(limit: e.limit) : t.homeRows.saveFailed;

/// "Add to Home" (or "Remove from Home") and "Manage Home" for one row, for
/// the top of a row's hold-OK menu. Empty when Trakt isn't connected.
List<MediaMenuExtraEntry> homeRowMenuEntries(BuildContext context, HomeRowEntry row) {
  final source = homeLayoutSourceOf(context);
  if (source == null) return const [];
  final onHome = source.pins.contains(row.id);
  return [
    MediaMenuExtraEntry(
      icon: onHome ? Symbols.remove_circle_rounded : Symbols.add_circle_rounded,
      label: onHome ? t.homeRows.removeFromHome : t.homeRows.addToHome,
      onSelected: () => unawaited(onHome ? removeHomeRow(context, row) : addHomeRows(context, [row])),
    ),
    MediaMenuExtraEntry(
      icon: Symbols.tune_rounded,
      label: t.homeRows.manageHome,
      onSelected: () => openHomeRows(context),
    ),
  ];
}

Future<void> addHomeRows(BuildContext context, List<HomeRowEntry> rows) async {
  final source = homeLayoutSourceOf(context);
  if (source == null || rows.isEmpty) return;
  try {
    final added = await source.pins.add(rows);
    if (!context.mounted) return;
    if (added == 0) {
      showAppSnackBar(context, t.homeRows.alreadyOnHome(title: rows.first.title));
    } else {
      showSuccessSnackBar(
        context,
        rows.length == 1 ? t.homeRows.added(title: rows.first.title) : t.homeRows.addedCount(count: added),
      );
    }
  } catch (e) {
    appLogger.w('Home rows: add failed', error: e);
    if (context.mounted) showErrorSnackBar(context, homeRowsSaveError(e));
  }
}

/// Remove [row] from Home; Continue Watching asks first.
Future<void> removeHomeRow(BuildContext context, HomeRowEntry row, {bool announce = true}) async {
  final source = homeLayoutSourceOf(context);
  if (source == null) return;
  if (row.id == HomeRowIds.continueWatching) {
    final confirmed = await showConfirmDialog(
      context,
      title: t.homeRows.removeContinueWatchingTitle(title: row.title),
      message: t.homeRows.removeContinueWatchingMessage,
      confirmText: t.homeRows.removeFromHome,
      isDestructive: true,
    );
    if (!confirmed || !context.mounted) return;
  }
  try {
    await source.pins.remove([row.id]);
    if (announce && context.mounted) showSuccessSnackBar(context, t.homeRows.removed(title: row.title));
  } catch (e) {
    appLogger.w('Home rows: remove failed', error: e);
    if (context.mounted) showErrorSnackBar(context, homeRowsSaveError(e));
  }
}

void openHomeRows(BuildContext context) {
  final source = homeLayoutSourceOf(context);
  if (source == null) return;
  unawaited(Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => HomeRowsScreen(source: source))));
}
