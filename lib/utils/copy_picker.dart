import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../i18n/strings.g.dart';
import '../media/copy_fallback.dart';
import '../media/ids.dart';
import '../media/media_item.dart';
import '../media/media_item_merge.dart';
import '../media/media_version.dart';
import '../providers/multi_server_provider.dart';
import '../services/title_copy_lookup.dart';
import 'app_logger.dart';
import 'dialogs.dart';
import 'formatters.dart';

/// Fork: how long the picker waits for the other servers' copies before it
/// lists what it has. Each server's lookup has a longer deadline of its own,
/// but a viewer holding a remote should not wait that long for a list.
const Duration copyPickerLookupPatience = Duration(seconds: 10);

/// Every copy of [item] on the viewer's online servers, [item] first, with
/// their versions; just [item] when the lookup fails or is slow.
Future<List<MediaItem>> findCopiesOf(BuildContext context, MediaItem item) async {
  final multi = context.read<MultiServerProvider>();
  final lookup = TitleCopies.from(multi.aggregationService).forItem(item);
  if (lookup == null) return [item];
  try {
    final result = await lookup.timeout(copyPickerLookupPatience);
    return [item, ...result.items.where((copy) => copy.globalKey != item.globalKey)];
  } catch (e) {
    appLogger.d('Copy picker: lookup of other copies failed', error: e);
    return [item];
  }
}

/// "Dolby Vision" or "HDR" when [version]'s video stream says so, else null.
String? versionDynamicRangeLabel(MediaVersion? version) {
  if (version == null) return null;
  var hdr = false;
  for (final part in version.parts) {
    for (final stream in part.streams) {
      if (stream.dolbyVision) return t.fileInfo.dolbyVision;
      if (stream.hdr) hdr = true;
    }
  }
  return hdr ? t.videoSettings.hdr : null;
}

/// Total size of [version]'s files, or null when any part has none.
int? versionSizeBytes(MediaVersion? version) {
  if (version == null || version.parts.isEmpty) return null;
  var total = 0;
  for (final part in version.parts) {
    final size = part.sizeBytes;
    if (size == null || size <= 0) return null;
    total += size;
  }
  return total;
}

/// Where [copy] lives, as the viewer named it: library, then server.
String copyLocationLabel(MediaItem copy) {
  final names = [?copy.libraryTitle, ?copy.serverName];
  return names.isEmpty ? (copy.backend.dialect?.productName ?? 'Plex') : names.join(' • ');
}

/// One row of [showCopyPicker]: quality and bitrate ("4K HEVC MKV
/// (45.0 Mbps)"), HDR or Dolby Vision, size, library and server, and the
/// marks. Library names need not mention resolution, so the row states it
/// (#1754), like the copy list on the Explore page.
String copySourceChoiceLabel(
  CopySource source, {
  bool didNotPlay = false,
  bool isDefault = false,
  bool isPlaying = false,
}) {
  final version = source.version;
  final size = versionSizeBytes(version);
  return [
    version?.displayLabel ?? libraryCopyQualityLabel(source.copy) ?? t.common.unknown,
    ?versionDynamicRangeLabel(version),
    if (size != null) ByteFormatter.formatBytes(size),
    copyLocationLabel(source.copy),
    if (isPlaying) t.copies.playingMark else if (isDefault) t.copies.defaultMark,
    if (didNotPlay) t.copies.didNotPlayMark,
  ].join(' • ');
}

/// Every file of [copies], highest bitrate first (the order Play's default
/// follows), then [compareLibraryCopies].
List<CopySource> copyPickerSources(Iterable<MediaItem> copies) {
  final sources = expandCopySources(copies);
  sources.sort((a, b) {
    final byBitrate = b.bitrate.compareTo(a.bitrate);
    if (byBitrate != 0) return byBitrate;
    final byHeight = (b.height ?? 0).compareTo(a.height ?? 0);
    if (byHeight != 0) return byHeight;
    final byCopy = compareLibraryCopies(a.copy, b.copy);
    return byCopy != 0 ? byCopy : a.versionIndex.compareTo(b.versionIndex);
  });
  return sources;
}

/// Fork: the copy picker. Lists every file of [item] on every online server
/// and library: each version of each copy, labelled by
/// [copySourceChoiceLabel], in a focusable option list the remote can walk.
/// Returns the file picked, or null when dismissed.
///
/// [copies] are used as given when the caller already has them (the player,
/// after a failed open); otherwise they are looked up behind a spinner.
/// [didNotPlay] marks files that failed to open. [include] drops files the
/// caller can't open (another backend, an offline server).
///
/// [playing] (the file on screen) or else [defaultSource] (what plain Play
/// opens) is marked and listed first, so the remote's first focus is the
/// file Play would have picked anyway.
Future<CopySource?> showCopyPicker(
  BuildContext context, {
  required MediaItem item,
  List<MediaItem>? copies,
  bool Function(CopySource source)? didNotPlay,
  bool Function(CopySource source)? include,
  CopySource? defaultSource,
  CopySource? playing,
}) async {
  var found = copies;
  if (found == null) {
    final loading = ScopedLoadingDialogController();
    loading.show(
      context,
      builder: (_) => const PopScope(canPop: false, child: Center(child: CircularProgressIndicator())),
    );
    try {
      found = await findCopiesOf(context, item);
    } finally {
      await loading.dismiss();
    }
    if (!context.mounted) return null;
  }
  final multi = context.read<MultiServerProvider>();
  final sources = [
    for (final source in copyPickerSources(found))
      if (_online(multi, source.copy) && (include?.call(source) ?? true)) source,
  ];
  if (sources.isEmpty) return null;
  final first = playing ?? defaultSource;
  if (first != null) {
    final index = sources.indexWhere((source) => source.key == first.key);
    if (index > 0) sources.insert(0, sources.removeAt(index));
  }
  return showOptionPickerDialog<CopySource>(
    context,
    title: t.copies.pickerTitle,
    options: [
      for (final source in sources)
        () {
          final failed = didNotPlay?.call(source) ?? false;
          final isPlaying = source.key == playing?.key;
          final isDefault = source.key == defaultSource?.key;
          return (
            icon: failed
                ? Symbols.error_rounded
                : isPlaying
                ? Symbols.play_circle_rounded
                : isDefault
                ? Symbols.star_rounded
                : Symbols.video_file_rounded,
            label: copySourceChoiceLabel(source, didNotPlay: failed, isDefault: isDefault, isPlaying: isPlaying),
            value: source,
          );
        }(),
    ],
  );
}

bool _online(MultiServerProvider multi, MediaItem copy) {
  final id = serverIdOrNull(copy.serverId);
  return id != null && multi.serverManager.isClientOnline(id);
}
