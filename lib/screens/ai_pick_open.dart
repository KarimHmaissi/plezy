import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../i18n/strings.g.dart';
import '../media/ids.dart';
import '../media/media_item.dart';
import '../media/media_item_merge.dart';
import '../providers/multi_server_provider.dart';
import '../services/broken_copies.dart';
import '../utils/app_logger.dart';
import '../utils/external_ids.dart';
import '../utils/media_navigation_helper.dart';
import '../utils/snackbar_helper.dart';

/// Phone tap: open the pick's page, like a card anywhere else. A title on
/// more than one server opens its highest-bitrate copy on a reachable
/// server. The pick is looked up on this phone's own server connections;
/// Play on its page then casts (or plays here when not connected).
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
  await BrokenCopies.instance.ensureLoaded();
  if (!context.mounted) return;
  // The highest-bitrate copy on a reachable server that has not failed to
  // play recently; no question asked.
  MediaItem? target = bestLibraryCopy(
    copies,
    isAvailable: (copy) {
      final id = serverIdOrNull(copy.serverId);
      return id != null && multi.isServerOnline(id);
    },
    isBroken: BrokenCopies.instance.isCopyBroken,
  );
  final pickServer = serverIdOrNull(item.serverId);
  if (target == null && pickServer != null && multi.getClientForServer(pickServer) != null) target = item;
  if (target == null) {
    showErrorSnackBar(context, t.aiTab.pickUnavailable);
    return;
  }
  await navigateToMediaItem(context, target);
}
