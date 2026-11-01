import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../i18n/strings.g.dart';
import '../media/catalog_item_ref.dart';
import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../mixins/debounced_media_search.dart';
import '../models/catalog/catalog_item.dart';
import '../services/catalog/trakt_catalog_source.dart';
import '../services/comfort/comfort_shows_controller.dart';
import '../services/settings_service.dart';
import '../utils/app_logger.dart';
import '../utils/dialogs.dart';
import '../utils/focus_utils.dart';
import '../utils/platform_detector.dart';
import '../utils/snackbar_helper.dart';
import '../widgets/app_icon.dart';
import '../widgets/focusable_list_tile.dart';
import '../widgets/focused_scroll_scaffold.dart';
import '../widgets/loading_indicator_box.dart';
import '../widgets/search_input_field.dart';
import '../widgets/setting_tile.dart';
import 'libraries/state_messages.dart';
import '../theme/fork_motion.dart';

/// Configure the comfort shows: whether Random episode plays straight away,
/// which shows are in the mix (synced through the Trakt list), and adding or
/// removing shows on the list.
class ComfortConfigureScreen extends StatelessWidget {
  final ComfortShowsController controller;
  final TraktCatalogSource source;

  const ComfortConfigureScreen({super.key, required this.controller, required this.source});

  Future<void> _toggle(BuildContext context, CatalogItem show, bool inMix) async {
    try {
      await controller.setPaused(show, !inMix);
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, t.comfort.updateFailed);
    }
  }

  Future<void> _remove(BuildContext context) async {
    final show = await showScopedDialog<CatalogItem>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(t.comfort.remove),
        children: [
          for (final (i, show) in controller.shows.indexed)
            FocusableListTile(
              autofocus: i == 0,
              leading: const AppIcon(Symbols.remove_circle_outline_rounded),
              title: Text(show.title),
              subtitle: show.year == null ? null : Text('${show.year}'),
              onTap: () => Navigator.pop(dialogContext, show),
            ),
        ],
      ),
    );
    if (show == null || !context.mounted) return;
    try {
      await controller.removeShow(show);
    } catch (e) {
      appLogger.w('Comfort: remove failed', error: e);
      if (context.mounted) showErrorSnackBar(context, t.comfort.updateFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => FocusedScrollScaffold(
        title: Text(t.comfort.configure),
        slivers: [
          SliverList.list(
            children: [
              SettingSwitchTile(
                pref: SettingsService.comfortPlayImmediately,
                icon: Symbols.play_circle_rounded,
                title: t.comfort.playImmediately,
                subtitle: t.comfort.playImmediatelyDescription,
              ),
              const Divider(),
              ListTile(
                title: Text(t.comfort.showsSection, style: Theme.of(context).textTheme.titleMedium),
                subtitle: Text(t.comfort.showsSectionDescription),
              ),
              for (final show in controller.shows)
                FocusableSwitchListTile(
                  secondary: AppIcon(
                    controller.isPaused(show) ? Symbols.pause_circle_rounded : Symbols.weekend_rounded,
                    fill: 1,
                  ),
                  title: Text(show.title),
                  subtitle: show.year == null ? null : Text('${show.year}'),
                  value: !controller.isPaused(show),
                  onChanged: (inMix) => unawaited(_toggle(context, show, inMix)),
                ),
              const Divider(),
              FocusableListTile(
                leading: const AppIcon(Symbols.add_circle_rounded, fill: 1),
                title: Text(t.comfort.addShow),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ComfortAddShowScreen(controller: controller, source: source),
                  ),
                ),
              ),
              if (controller.shows.isNotEmpty)
                FocusableListTile(
                  leading: const AppIcon(Symbols.remove_circle_rounded, fill: 1),
                  title: Text(t.comfort.remove),
                  onTap: () => unawaited(_remove(context)),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Search Trakt for a show and add it to the comfort list.
class ComfortAddShowScreen extends StatefulWidget {
  final ComfortShowsController controller;
  final TraktCatalogSource source;

  const ComfortAddShowScreen({super.key, required this.controller, required this.source});

  @override
  State<ComfortAddShowScreen> createState() => _ComfortAddShowScreenState();
}

class _ComfortAddShowScreenState extends State<ComfortAddShowScreen>
    with DebouncedMediaSearch<ComfortAddShowScreen, MediaItem> {
  bool _adding = false;

  @override
  String get searchDebugLabel => 'ComfortAddShow';

  @override
  Future<List<MediaItem>> performSearchQuery(String query) async {
    final items = await widget.source.search(query);
    return [
      for (final item in items)
        if (item.kind == MediaKind.show) item.toMediaItem(),
    ];
  }

  @override
  void initState() {
    super.initState();
    FocusUtils.requestFocusAfterBuild(this, searchFocusNode);
  }

  Future<void> _add(MediaItem item) async {
    final show = item.catalogItem;
    if (show == null || _adding) return;
    setState(() => _adding = true);
    try {
      await widget.controller.addShow(show);
      ForkMotion.success();
      if (!mounted) return;
      showAppSnackBar(context, t.comfort.added(title: show.title));
      Navigator.of(context).pop();
    } catch (e) {
      appLogger.w('Comfort: add failed', error: e);
      if (mounted) showErrorSnackBar(context, t.comfort.updateFailed);
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final onList = {for (final show in widget.controller.shows) show.identityKey};
    return FocusedScrollScaffold(
      title: Text(t.comfort.addShow),
      slivers: [
        SliverToBoxAdapter(
          child: SearchInputField(
            controller: searchController,
            focusNode: searchFocusNode,
            debugLabel: searchDebugLabel,
            hintText: t.comfort.searchHint,
            onNavigateDown: searchResults.isNotEmpty && !isSearching ? firstResultFocusNode.requestFocus : null,
            onEditingComplete: PlatformDetector.isTV() ? handleSearchSubmit : null,
          ),
        ),
        if (isSearching || _adding)
          LoadingIndicatorBox.sliver
        else if (hasSearched && lastSearchFailed)
          SliverFillRemaining(
            child: StateMessageWidget(message: t.explore.searchFailed, icon: Symbols.error_rounded, iconSize: 80),
          )
        else if (hasSearched && searchResults.isEmpty)
          SliverFillRemaining(
            child: StateMessageWidget(
              message: t.explore.searchEmpty(query: lastSearchedQuery),
              icon: Symbols.search_off_rounded,
              iconSize: 80,
            ),
          )
        else
          buildResultsSliver((context, index) {
            final item = searchResults[index];
            final show = item.catalogItem;
            final already = show != null && onList.contains(show.identityKey);
            return FocusableListTile(
              key: Key(item.globalKey),
              focusNode: index == 0 ? firstResultFocusNode : null,
              leading: AppIcon(already ? Symbols.check_circle_rounded : Symbols.add_circle_outline_rounded),
              title: Text(item.title ?? show?.title ?? ''),
              subtitle: show?.year == null ? null : Text('${show!.year}'),
              enabled: !already,
              onTap: already ? null : () => unawaited(_add(item)),
            );
          }),
      ],
    );
  }
}
