import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../i18n/strings.g.dart';
import '../media/ids.dart';
import '../media/media_item.dart';
import '../media/media_item_merge.dart';
import '../providers/multi_server_provider.dart';
import '../theme/fork_motion.dart';
import '../utils/app_logger.dart';
import '../utils/external_ids.dart';
import '../utils/media_navigation_helper.dart';
import '../utils/snackbar_helper.dart';

/// Phone tap: open the pick's page, like a card anywhere else. A title on
/// more than one server asks which copy first. The pick is looked up on
/// this phone's own server connections; Play on its page then casts (or
/// plays here when not connected).
Future<void> openAiPick(BuildContext context, MediaItem item) async {
  final multi = context.read<MultiServerProvider>();
  var copies = <MediaItem>[];
  final guid = item.guid;
  if (guid != null && guid.isNotEmpty) {
    try {
      final result = await multi.aggregationService.findByExternalIdsAcrossServers(
        const ExternalIds(),
        kind: item.kind,
        serverIds: multi.expectedServerIds.toSet(),
        plexGuid: guid,
        titles: [?item.title],
        year: item.year,
      );
      copies = mergeLibraryCopies(const [], result.items);
    } catch (e) {
      appLogger.d('AI: copy lookup for a pick failed', error: e);
    }
  }
  if (!context.mounted) return;
  final servers = {for (final c in copies) c.serverId};
  MediaItem? target;
  if (servers.length > 1) {
    target = await _chooseCopy(context, copies);
    if (target == null || !context.mounted) return;
  } else if (copies.isNotEmpty) {
    target = copies.first;
  } else if (serverIdOrNull(item.serverId) case final id? when multi.getClientForServer(id) != null) {
    target = item;
  }
  if (target == null) {
    showErrorSnackBar(context, t.aiTab.pickUnavailable);
    return;
  }
  await navigateToMediaItem(context, target);
}

Future<MediaItem?> _chooseCopy(BuildContext context, List<MediaItem> copies) => showModalBottomSheet<MediaItem>(
  context: context,
  showDragHandle: true,
  builder: (context) => SafeArea(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Text(t.aiTab.chooseCopy, style: Theme.of(context).textTheme.titleMedium),
        ),
        for (final copy in copies)
          ListTile(
            leading: const Icon(Symbols.dns_rounded),
            title: Text(copy.serverName ?? copy.libraryTitle ?? '?'),
            subtitle: Text([?copy.libraryTitle, ?libraryCopyQualityLabel(copy)].join(' · ')),
            onTap: () {
              ForkMotion.selection();
              Navigator.of(context).pop(copy);
            },
          ),
        const SizedBox(height: 8),
      ],
    ),
  ),
);
