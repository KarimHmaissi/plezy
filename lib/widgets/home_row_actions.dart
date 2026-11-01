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

/// The Trakt Lists source, when Trakt is connected (Manage Home lists its
/// charts and lists).
TraktListsCatalogSource? traktListsSourceOf(BuildContext context) => Provider.of<CatalogSourcesProvider?>(
  context,
  listen: false,
)?.connectedSources.whereType<TraktListsCatalogSource>().firstOrNull;

/// "Add to Home" (or "Remove from Home") and "Manage Home" for one row, for
/// the top of a row's hold-OK menu.
List<MediaMenuExtraEntry> homeRowMenuEntries(BuildContext context, HomeRowEntry row) {
  final onHome = HomePinsController.instance.contains(row.id);
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
  if (rows.isEmpty) return;
  try {
    final added = await HomePinsController.instance.add(rows);
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
    if (context.mounted) showErrorSnackBar(context, t.homeRows.saveFailed);
  }
}

/// Remove [row] from Home; Continue Watching asks first.
Future<void> removeHomeRow(BuildContext context, HomeRowEntry row, {bool announce = true}) async {
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
    await HomePinsController.instance.remove([row.id]);
    if (announce && context.mounted) showSuccessSnackBar(context, t.homeRows.removed(title: row.title));
  } catch (e) {
    appLogger.w('Home rows: remove failed', error: e);
    if (context.mounted) showErrorSnackBar(context, t.homeRows.saveFailed);
  }
}

void openHomeRows(BuildContext context) {
  unawaited(
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => HomeRowsScreen(source: traktListsSourceOf(context)))),
  );
}
