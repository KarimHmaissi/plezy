import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import '../../services/reel/reel_clip_cache.dart';
import '../../utils/dialogs.dart';
import '../../utils/formatters.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/setting_tile.dart';

/// Fork: the Reel settings page's Clear Reel cache row (plan V2-10). Its
/// subtitle says how much of the cap the clip core's disk cache holds; a
/// tap asks first, then empties it, like Settings' Clear image cache row.
class ReelClipCacheTile extends StatefulWidget {
  const ReelClipCacheTile({super.key, this.cache});

  /// Defaults to [ReelClipCache.instance].
  final ReelClipCache? cache;

  /// "84.0 MB of 192 MB on this device", or what the row does until the
  /// usage is known (or when there is no room for a cache).
  static String subtitleFor(ReelClipCacheUsage? usage) {
    final s = t.reel.settings;
    if (usage == null || usage.capBytes <= 0) return s.clearCacheDescription;
    return s.clearCacheUsage(
      used: ByteFormatter.formatBytes(usage.bytes),
      cap: ByteFormatter.formatBytes(usage.capBytes, decimals: 0),
    );
  }

  @override
  State<ReelClipCacheTile> createState() => _ReelClipCacheTileState();
}

class _ReelClipCacheTileState extends State<ReelClipCacheTile> {
  ReelClipCache get _cache => widget.cache ?? ReelClipCache.instance;
  ReelClipCacheUsage? _usage;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final usage = await _cache.usage();
    if (mounted) setState(() => _usage = usage);
  }

  Future<void> _clear() async {
    final s = t.reel.settings;
    final confirmed = await showConfirmDialog(
      context,
      title: s.clearCache,
      message: s.clearCacheConfirm,
      confirmText: t.common.clear,
    );
    if (!confirmed || !mounted) return;
    final freed = await _cache.clear();
    if (!mounted) return;
    if (freed == null) {
      showErrorSnackBar(context, s.clearCacheFailed);
    } else {
      showSuccessSnackBar(context, s.clearCacheDone);
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return SettingNavigationTile(
      icon: Symbols.cleaning_services_rounded,
      title: t.reel.settings.clearCache,
      subtitle: ReelClipCacheTile.subtitleFor(_usage),
      onTap: _clear,
    );
  }
}
