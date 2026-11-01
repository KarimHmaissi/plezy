import 'package:flutter/material.dart';

import '../models/catalog/catalog_item.dart';
import '../screens/catalog_item_detail_screen.dart';
import 'package:provider/provider.dart';
import '../media/ids.dart';
import '../media/media_item.dart';
import '../media/media_item_merge.dart';
import '../providers/multi_server_provider.dart';
import '../services/catalog/catalog_library_matcher.dart';
import 'app_logger.dart';
import 'media_navigation_helper.dart';

/// Open a catalog item (Explore tab tap sink, routed here by the catalog
/// branches in `navigateToMediaItem` / `navigateToMediaItemDetails`).
///
/// Fork: a title that's in the library opens its library page straight
/// away, on the copy with the highest bitrate on a reachable server; one
/// that isn't (or when the lookup is slow) lands on
/// [CatalogItemDetailScreen], which lists every copy. [chooseCopy] always
/// goes there (the long-press menu's "All copies").
Future<void> navigateToCatalogItem(BuildContext context, CatalogItem item, {bool chooseCopy = false}) async {
  if (!chooseCopy) {
    final best = await _bestLibraryCopy(context, item);
    if (!context.mounted) return;
    if (best != null) {
      await navigateToMediaItemDetails(context, best);
      return;
    }
  }
  await Navigator.push(context, MaterialPageRoute(builder: (_) => CatalogItemDetailScreen(item: item)));
}

Future<MediaItem?> _bestLibraryCopy(BuildContext context, CatalogItem item) async {
  try {
    final multi = context.read<MultiServerProvider>();
    final result = await context.read<CatalogLibraryMatcher>().match(item).timeout(const Duration(seconds: 3));
    return bestLibraryCopy(
      result.items,
      isAvailable: (copy) {
        final id = serverIdOrNull(copy.serverId);
        return id != null && multi.isServerOnline(id);
      },
    );
  } catch (e) {
    appLogger.d('Catalog: best-copy lookup failed', error: e);
    return null;
  }
}
