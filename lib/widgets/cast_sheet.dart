import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../i18n/strings.g.dart';
import '../media/ids.dart';
import '../media/media_item.dart';
import '../providers/cast_provider.dart';
import '../services/casting/google_cast_channel.dart';
import '../theme/fork_motion.dart';
import '../utils/formatters.dart';
import '../utils/provider_extensions.dart';
import '../utils/snackbar_helper.dart';
import 'app_icon.dart';
import 'optimized_media_image.dart';

/// Fork: cast [item] to the connected Google Cast device, telling the user
/// how it went.
Future<void> castToDevice(
  BuildContext context,
  CastProvider cast,
  MediaItem item, {
  Duration start = Duration.zero,
}) async {
  final device = cast.deviceName ?? t.googleCast.device;
  showAppSnackBar(context, t.cast.sending(title: item.displayTitle, name: device));
  try {
    await cast.play(item, start: start);
  } on CastException catch (e) {
    if (!context.mounted) return;
    showErrorSnackBar(context, switch (e.reason) {
      CastFailure.notPlex => t.googleCast.notPlex,
      CastFailure.noStream => t.googleCast.noStream,
      CastFailure.loadFailed => t.googleCast.loadFailed(name: device),
    });
  }
}

/// The Cast icon in the phone's top bar: outlined when idle, filled while
/// connected. Hidden where casting isn't available.
class CastButton extends StatelessWidget {
  const CastButton({super.key, required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    final cast = context.watch<CastProvider?>();
    if (cast == null || !cast.available) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final connected = cast.isConnected;
    return IconButton(
      tooltip: t.googleCast.button,
      onPressed: () => openCastPicker(context),
      icon: cast.sessionState == CastSessionState.connecting
          ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: color))
          : AppIcon(
              connected ? Symbols.cast_connected_rounded : Symbols.cast_rounded,
              fill: connected ? 1 : 0,
              color: connected ? scheme.primary : color,
            ),
    );
  }
}

/// From the Cast button or mini bar: the device picker when not connected,
/// the controls for what is casting, or the connected device's sheet.
Future<void> openCastPicker(BuildContext context) {
  ForkMotion.selection();
  final cast = context.read<CastProvider>();
  if (cast.isConnected && cast.title != null) return CastNowPlayingScreen.open(context);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => ChangeNotifierProvider.value(value: cast, child: const _CastDevicesSheet()),
  );
}

class _CastDevicesSheet extends StatefulWidget {
  const _CastDevicesSheet();

  @override
  State<_CastDevicesSheet> createState() => _CastDevicesSheetState();
}

class _CastDevicesSheetState extends State<_CastDevicesSheet> {
  late final CastProvider _cast = context.read<CastProvider>();
  bool _wasConnected = false;

  @override
  void initState() {
    super.initState();
    _wasConnected = _cast.isConnected;
    _cast.addListener(_onChange);
    unawaited(_cast.startDiscovery());
  }

  @override
  void dispose() {
    _cast.removeListener(_onChange);
    unawaited(_cast.stopDiscovery());
    super.dispose();
  }

  /// Close once a device we picked here connects.
  void _onChange() {
    if (!_wasConnected && _cast.isConnected && mounted) {
      Navigator.of(context).maybePop();
      showAppSnackBar(context, t.googleCast.connected(name: _cast.deviceName ?? t.googleCast.device));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cast = context.watch<CastProvider>();
    final theme = Theme.of(context);
    final connected = cast.isConnected;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                connected ? t.cast.playingOn(name: cast.deviceName ?? t.googleCast.device) : t.googleCast.castTo,
                style: theme.textTheme.titleLarge,
              ),
            ),
            if (connected) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                child: Text(
                  t.googleCast.connectedHint,
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
              ListTile(
                leading: const Icon(Symbols.cast_rounded),
                title: Text(t.googleCast.stopCasting),
                onTap: () {
                  ForkMotion.selection();
                  unawaited(cast.disconnect());
                  Navigator.of(context).maybePop();
                },
              ),
            ] else ...[
              for (final route in cast.routes)
                ListTile(
                  leading: Icon(
                    route.description.toLowerCase().contains('speaker') ? Symbols.speaker_rounded : Symbols.tv_rounded,
                  ),
                  title: Text(route.name),
                  subtitle: route.description.isEmpty ? null : Text(route.description),
                  trailing: cast.sessionState == CastSessionState.connecting && route.selected
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : null,
                  onTap: () {
                    ForkMotion.selection();
                    unawaited(cast.connect(route));
                  },
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
                child: Row(
                  children: [
                    const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        cast.routes.isEmpty ? t.googleCast.searching : t.googleCast.searchingMore,
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A slim bar over the bottom navigation while something is casting: the
/// title, its progress and play/pause; tap for the full controls.
class CastMiniBar extends StatefulWidget {
  const CastMiniBar({super.key});

  @override
  State<CastMiniBar> createState() => _CastMiniBarState();
}

class _CastMiniBarState extends State<CastMiniBar> {
  Timer? _tick;

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  /// Keep the progress line moving between the receiver's updates.
  void _syncTick(bool playing) {
    if (playing && _tick == null) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!playing) {
      _tick?.cancel();
      _tick = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cast = context.watch<CastProvider?>();
    final title = cast?.title;
    final status = cast?.status;
    _syncTick(status?.playing ?? false);
    if (cast == null || !cast.isConnected || title == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final name = cast.deviceName ?? t.googleCast.device;
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      child: InkWell(
        onTap: () => unawaited(CastNowPlayingScreen.open(context)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(value: status?.progress ?? 0, minHeight: 2),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 5, 4, 5),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: OptimizedMediaImage(
                      client: context.tryGetMediaClientWithFallback(serverIdOrNull(title.serverId)),
                      imagePath: title.thumbPath,
                      width: 64,
                      height: 36,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title.title,
                          style: theme.textTheme.labelLarge?.copyWith(height: 1.15),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          t.cast.playingOn(name: name),
                          style: theme.textTheme.bodySmall?.copyWith(height: 1.15),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Icon(Symbols.cast_connected_rounded, size: 20),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: t.cast.playPause,
                    onPressed: status == null
                        ? null
                        : () {
                            ForkMotion.selection();
                            unawaited(cast.togglePlay());
                          },
                    icon: Icon(status?.playing ?? false ? Symbols.pause_rounded : Symbols.play_arrow_rounded, fill: 1),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Phone: full controls for what is casting, laid out like the companion
/// TV's now-playing screen.
class CastNowPlayingScreen extends StatefulWidget {
  const CastNowPlayingScreen({super.key});

  static Future<void> open(BuildContext context) {
    final cast = context.read<CastProvider>();
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      enableDrag: true,
      builder: (_) => ChangeNotifierProvider.value(
        value: cast,
        child: const FractionallySizedBox(heightFactor: 1, child: CastNowPlayingScreen()),
      ),
    );
  }

  @override
  State<CastNowPlayingScreen> createState() => _CastNowPlayingScreenState();
}

class _CastNowPlayingScreenState extends State<CastNowPlayingScreen> {
  late final CastProvider _cast = context.read<CastProvider>();
  Timer? _tick;
  double? _dragValue;

  /// Where a seek was dropped, held until the receiver reports past it.
  Duration? _pendingSeek;

  @override
  void initState() {
    super.initState();
    _cast.addListener(_onChange);
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted && (_cast.status?.playing ?? false) && _dragValue == null) setState(() {});
    });
  }

  @override
  void dispose() {
    _cast.removeListener(_onChange);
    _tick?.cancel();
    super.dispose();
  }

  void _onChange() {
    // The title ended or the device went away.
    if (mounted && (_cast.title == null || !_cast.isConnected)) Navigator.of(context).maybePop();
  }

  Widget _artwork(CastingTitle title) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: OptimizedMediaImage(
          client: context.tryGetMediaClientWithFallback(serverIdOrNull(title.serverId)),
          imagePath: title.item?.artPath ?? title.thumbPath,
          width: double.infinity,
          height: double.infinity,
          fit: BoxFit.cover,
        ),
      ),
    );
  }

  Widget _controls(CastingTitle title, CastMediaStatus? status) {
    final theme = Theme.of(context);
    final total = status?.duration ?? Duration.zero;
    var position = status?.position ?? Duration.zero;
    final pending = _pendingSeek;
    if (pending != null) {
      if ((position - pending).abs() > const Duration(seconds: 3)) {
        position = pending;
      } else {
        _pendingSeek = null;
      }
    }
    if (_dragValue != null) position = Duration(milliseconds: (_dragValue! * total.inMilliseconds).round());
    final progress = total.inMilliseconds <= 0 ? 0.0 : (position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
    final buffering = status == null || status.state == 'buffering' || _cast.starting;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title.title, style: theme.textTheme.headlineSmall, maxLines: 2, overflow: TextOverflow.ellipsis),
        if (title.subtitle?.isNotEmpty ?? false)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              title.subtitle!,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        const SizedBox(height: 16),
        Slider(
          value: progress,
          onChanged: total > Duration.zero ? (v) => setState(() => _dragValue = v) : null,
          onChangeEnd: (v) {
            final target = Duration(milliseconds: (v * total.inMilliseconds).round());
            unawaited(_cast.seek(target));
            setState(() {
              _pendingSeek = target;
              _dragValue = null;
            });
          },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(formatDurationTimestamp(position), style: theme.textTheme.bodySmall),
              Text('-${formatDurationTimestamp(total - position)}', style: theme.textTheme.bodySmall),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            IconButton(
              iconSize: 36,
              tooltip: t.cast.back10,
              onPressed: () {
                ForkMotion.selection();
                unawaited(_cast.seekBy(const Duration(seconds: -10)));
              },
              icon: const Icon(Symbols.replay_10_rounded),
            ),
            IconButton.filled(
              iconSize: 44,
              onPressed: () {
                ForkMotion.selection();
                unawaited(_cast.togglePlay());
              },
              icon: buffering
                  ? const SizedBox(width: 44, height: 44, child: CircularProgressIndicator(strokeWidth: 3))
                  : Icon(status.playing ? Symbols.pause_rounded : Symbols.play_arrow_rounded, fill: 1),
            ),
            IconButton(
              iconSize: 36,
              tooltip: t.cast.forward10,
              onPressed: () {
                ForkMotion.selection();
                unawaited(_cast.seekBy(const Duration(seconds: 30)));
              },
              icon: const Icon(Symbols.forward_30_rounded),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: () => unawaited(_cast.stop()),
              icon: const Icon(Symbols.stop_rounded),
              label: Text(t.cast.stop),
            ),
            OutlinedButton.icon(
              onPressed: () => unawaited(_cast.disconnect()),
              icon: const Icon(Symbols.cast_rounded),
              label: Text(t.googleCast.stopCasting),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final cast = context.watch<CastProvider>();
    final title = cast.title;
    final status = cast.status;
    final name = cast.deviceName ?? t.googleCast.device;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Symbols.keyboard_arrow_down_rounded),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(t.cast.playingOn(name: name)),
      ),
      body: SafeArea(
        child: title == null
            ? Center(child: Text(t.cast.nothingPlaying))
            : LayoutBuilder(
                builder: (context, constraints) {
                  // Unfolded (wide): artwork beside the controls.
                  final wide = constraints.maxWidth >= 700 && constraints.maxWidth > constraints.maxHeight * 0.9;
                  if (wide) {
                    return Padding(
                      padding: const EdgeInsets.all(24),
                      child: Row(
                        children: [
                          Expanded(child: Center(child: _artwork(title))),
                          const SizedBox(width: 32),
                          Expanded(child: SingleChildScrollView(child: _controls(title, status))),
                        ],
                      ),
                    );
                  }
                  return SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                    child: Column(children: [_artwork(title), const SizedBox(height: 24), _controls(title, status)]),
                  );
                },
              ),
      ),
    );
  }
}
