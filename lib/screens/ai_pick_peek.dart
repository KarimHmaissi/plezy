import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../i18n/strings.g.dart';
import '../media/ids.dart';
import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../providers/catalog_sources_provider.dart';
import '../services/catalog/library_watchlist_candidates.dart';
import '../theme/mono_tokens.dart';
import '../utils/app_logger.dart';
import '../utils/media_image_helper.dart';
import '../utils/provider_extensions.dart';
import '../utils/snackbar_helper.dart';
import '../widgets/optimized_media_image.dart';
import '../widgets/overlay_sheet.dart';
import '../widgets/watchlist_source_chooser.dart';

/// Fork: the top of a pick's long-press menu on the AI page: poster, title
/// and year, why it was picked (written on demand when the answer didn't
/// say), and Play, Watchlist and Details. The item's usual menu entries
/// follow it in the same sheet.
class AiPickPeekHeader extends StatelessWidget {
  const AiPickPeekHeader({
    super.key,
    required this.item,
    this.reason,
    this.loadReason,
    this.topPick,
    this.spotlight,
    required this.onPlay,
    required this.onDetails,
  });

  final MediaItem item;
  final String? reason;
  final Future<String?> Function()? loadReason;
  final String? topPick;
  final String? spotlight;
  final VoidCallback onPlay;
  final VoidCallback onDetails;

  @override
  Widget build(BuildContext context) => _AiPickPeek(
    item: item,
    reason: reason,
    loadReason: loadReason,
    topPick: topPick,
    spotlight: spotlight,
    onPlay: onPlay,
    onDetails: onDetails,
  );
}

class _AiPickPeek extends StatefulWidget {
  const _AiPickPeek({
    required this.item,
    required this.reason,
    required this.loadReason,
    required this.topPick,
    required this.spotlight,
    required this.onPlay,
    required this.onDetails,
  });

  final MediaItem item;
  final String? reason;
  final Future<String?> Function()? loadReason;
  final String? topPick;
  final String? spotlight;
  final VoidCallback onPlay;
  final VoidCallback onDetails;

  @override
  State<_AiPickPeek> createState() => _AiPickPeekState();
}

class _AiPickPeekState extends State<_AiPickPeek> {
  String? _reason;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _reason = widget.topPick ?? ((widget.reason?.trim().isNotEmpty ?? false) ? widget.reason!.trim() : null);
    if (_reason == null && widget.loadReason != null) {
      _loading = true;
      unawaited(
        widget.loadReason!().then((text) {
          if (mounted) {
            setState(() {
              _reason = text;
              _loading = false;
            });
          }
        }),
      );
    }
  }

  bool get _canWatchlist {
    final sources = Provider.of<CatalogSourcesProvider?>(context, listen: false);
    final kind = widget.item.kind;
    return sources != null &&
        sources.watchlistCapableSources.isNotEmpty &&
        (kind == MediaKind.movie || kind == MediaKind.show);
  }

  /// Adds (never removes) the pick, the way the card menu does.
  Future<void> _addToWatchlist() async {
    final sources = context.read<CatalogSourcesProvider>();
    final client = context.tryGetMediaClientWithFallback(serverIdOrNull(widget.item.serverId));
    try {
      final candidates = await sources.watchlistCandidatesFor(widget.item, client: client);
      if (!mounted) return;
      if (candidates.isEmpty) return showAppSnackBar(context, t.explore.watchlistNoMatch);
      final candidate = candidates.length == 1
          ? candidates.single
          : await showWatchlistSourceChooser(context, kind: widget.item.kind, candidates: candidates);
      if (candidate == null || !mounted) return;
      if (!await mutateWatchlistMembership(widget.item.kind, candidate, add: true)) return;
      if (mounted) showSuccessSnackBar(context, t.explore.addedToWatchlist);
    } catch (e, st) {
      appLogger.w('AI: watchlist add failed', error: e, stackTrace: st);
      if (mounted) showErrorSnackBar(context, t.explore.watchlistUpdateFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mono = tokens(context);
    final theme = Theme.of(context).textTheme;
    final item = widget.item;
    final meta = [
      if (item.year != null) '${item.year}',
      if (item.kind == MediaKind.show)
        t.common.mediaKind.show
      else if (item.kind == MediaKind.movie)
        t.common.mediaKind.movie,
    ].join(' · ');
    void close(VoidCallback action) {
      OverlaySheetController.closeAdaptive(context);
      action();
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(mono.radiusSm),
                child: OptimizedMediaImage(
                  client: context.tryGetMediaClientWithFallback(serverIdOrNull(item.serverId)),
                  imagePath: item.posterThumb(),
                  width: 72,
                  height: 108,
                  imageType: ImageType.poster,
                  fallbackIcon: Symbols.movie_rounded,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.title ?? '', style: theme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                    if (meta.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(meta, style: theme.bodyMedium?.copyWith(color: mono.textMuted)),
                    ],
                    if (widget.topPick != null) ...[
                      const SizedBox(height: 6),
                      Text(t.aiTab.topPick, style: theme.labelLarge?.copyWith(color: mono.textMuted)),
                    ],
                    const SizedBox(height: 10),
                    if (_loading)
                      Row(
                        children: [
                          SizedBox.square(
                            dimension: 14,
                            child: CircularProgressIndicator(strokeWidth: 2, color: mono.textMuted),
                          ),
                          const SizedBox(width: 10),
                          Flexible(
                            child: Text(t.aiTab.writingReason, style: theme.bodySmall?.copyWith(color: mono.textMuted)),
                          ),
                        ],
                      )
                    else if (_reason != null)
                      Text(_reason!, style: theme.bodyMedium?.copyWith(height: 1.4, color: mono.text)),
                    if (widget.spotlight != null) ...[
                      const SizedBox(height: 8),
                      Text(widget.spotlight!, style: theme.bodyMedium?.copyWith(height: 1.4, color: mono.textMuted)),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: () => close(widget.onPlay),
                icon: const Icon(Symbols.play_arrow_rounded, fill: 1),
                label: Text(t.common.play),
              ),
              if (_canWatchlist)
                OutlinedButton.icon(
                  onPressed: () => unawaited(_addToWatchlist()),
                  icon: const Icon(Symbols.bookmark_add_rounded),
                  label: Text(t.navigation.watchlist),
                ),
              OutlinedButton.icon(
                onPressed: () => close(widget.onDetails),
                icon: const Icon(Symbols.info_rounded),
                label: Text(t.aiTab.details),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
