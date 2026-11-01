import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../models/catalog/catalog_item.dart';
import '../../widgets/media_context_menu.dart' show MediaMenuExtraEntry;

/// A title to find more like: what the long-press menu knows about it.
typedef AiSeed = ({String title, int? year, MediaKind kind, String? guid});

/// "More like this" from any title's long-press menu: queues a request for
/// the AI tab and asks the main screen to switch to it. The AI tab takes the
/// queue when it's mounted or notified.
abstract final class AiMoreLikeThis {
  static final List<AiSeed> _queue = [];

  /// Bumped per request; the main screen listens to switch tabs.
  static final ValueNotifier<int> requests = ValueNotifier(0);

  static void request(AiSeed seed) {
    _queue.add(seed);
    requests.value++;
  }

  static List<AiSeed> take() {
    final seeds = List.of(_queue);
    _queue.clear();
    return seeds;
  }

  static bool _supports(MediaKind kind) => kind == MediaKind.movie || kind == MediaKind.show;

  static MediaMenuExtraEntry? entryForItem(MediaItem item) {
    // Episodes and seasons ask about their show.
    final show = switch (item.kind) {
      MediaKind.episode => item.grandparentTitle,
      MediaKind.season => item.parentTitle,
      _ => null,
    };
    if (show != null && show.isNotEmpty) {
      return _entry((title: show, year: null, kind: MediaKind.show, guid: null));
    }
    final title = item.title;
    if (!_supports(item.kind) || title == null || title.isEmpty) return null;
    return _entry((title: title, year: item.year, kind: item.kind, guid: item.guid));
  }

  static MediaMenuExtraEntry? entryForCatalog(CatalogItem item) {
    if (!_supports(item.kind) || item.title.isEmpty) return null;
    return _entry((title: item.title, year: item.year, kind: item.kind, guid: null));
  }

  static MediaMenuExtraEntry _entry(AiSeed seed) => MediaMenuExtraEntry(
    icon: Symbols.auto_awesome_rounded,
    label: t.aiTab.moreLikeThis,
    onSelected: () => request(seed),
  );

  /// The request sent to the helper (also what Refresh re-runs).
  static String prompt(AiSeed seed) {
    final kind = seed.kind == MediaKind.show ? 'show' : 'film';
    final details = [kind, ?seed.year?.toString(), if (seed.guid != null) 'guid ${seed.guid}'].join(', ');
    return 'More like "${seed.title}" ($details): find films and shows similar to it in tone, themes and '
        'feel. Leave "${seed.title}" itself out. Name the row (show_picks title) in a few words that '
        'include "${seed.title}", e.g. "Twisty sci-fi like Severance".';
  }
}
