import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../i18n/strings.g.dart';
import '../media/ids.dart';
import '../models/companion_remote/remote_command.dart';
import '../providers/companion_remote_provider.dart';
import '../providers/cast_provider.dart';
import '../screens/companion_remote/now_playing_screen.dart';
import '../utils/provider_extensions.dart';
import '../utils/snackbar_helper.dart';
import 'cast_sheet.dart';
import 'optimized_media_image.dart';
import '../theme/fork_motion.dart';

/// Phone side of casting: while connected to a TV app, shows where Play goes
/// (the TV, or this phone) and, while the TV is playing, a mini player that
/// opens the full now-playing screen. While a Cast or DLNA device plays one
/// of our titles, its mini player ([CastMiniBar]) shows instead.
class CastBar extends StatefulWidget {
  const CastBar({super.key});

  @override
  State<CastBar> createState() => _CastBarState();
}

class _CastBarState extends State<CastBar> {
  CompanionRemoteProvider? _remote;
  Timer? _tick;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final remote = context.read<CompanionRemoteProvider?>();
    if (identical(remote, _remote)) return;
    _remote?.castResults.removeListener(_onResult);
    _remote?.nowPlaying.removeListener(_onNowPlaying);
    _remote = remote;
    remote?.castResults.addListener(_onResult);
    remote?.nowPlaying.addListener(_onNowPlaying);
    _onNowPlaying();
  }

  @override
  void dispose() {
    _remote?.castResults.removeListener(_onResult);
    _remote?.nowPlaying.removeListener(_onNowPlaying);
    _tick?.cancel();
    super.dispose();
  }

  void _onResult() {
    final result = _remote?.castResults.value;
    if (result == null || !mounted || result.ok) return;
    showAppSnackBar(context, t.cast.failed(message: result.message));
  }

  /// Keep the progress line moving between the TV's updates.
  void _onNowPlaying() {
    final playing = _remote?.nowPlaying.value?['state'] == 'playing';
    if (playing && _tick == null) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!playing) {
      _tick?.cancel();
      _tick = null;
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // Fork: a title on a Cast or DLNA device takes the bar (Play goes there too).
    final castingToDevice = context.select<CastProvider?, bool>(
      (c) => c != null && c.isConnected && c.title != null,
    );
    if (castingToDevice) return const CastMiniBar();
    final remote = context.watch<CompanionRemoteProvider?>();
    if (remote == null || !remote.isRemote || !remote.isConnected) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final name = remote.connectedDevice?.name ?? t.companionRemote.unknownDevice;
    final casting = remote.castToHost;
    final data = remote.nowPlaying.value;
    if (data != null) return _miniPlayer(remote, HostNowPlaying(data), name, casting);
    return Material(
      color: casting ? theme.colorScheme.primaryContainer : theme.colorScheme.surfaceContainerHighest,
      child: InkWell(
        onTap: () => remote.setCastToHost(!casting),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Icon(casting ? Symbols.cast_connected_rounded : Symbols.smartphone_rounded, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  casting ? t.cast.playingOn(name: name) : t.cast.thisPhone,
                  style: theme.textTheme.labelLarge,
                ),
              ),
              Text(
                casting ? t.cast.switchToThisPhone : t.cast.switchToHost(name: name),
                style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.primary),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _miniPlayer(CompanionRemoteProvider remote, HostNowPlaying now, String name, bool casting) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      child: InkWell(
        onTap: () {
          ForkMotion.selection();
          unawaited(NowPlayingScreen.open(context));
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(value: now.progress, minHeight: 2),
            Padding(
              // Fork: slim, about 52dp with the progress line.
              padding: const EdgeInsets.fromLTRB(12, 5, 4, 5),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: OptimizedMediaImage(
                      client: context.tryGetMediaClientWithFallback(serverIdOrNull(now.serverId)),
                      imagePath: now.thumb ?? now.art ?? now.poster,
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
                          now.title,
                          style: theme.textTheme.labelLarge?.copyWith(height: 1.15),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          // Tapping the cast icon still switches where new Play goes.
                          casting ? t.cast.playingOn(name: name) : t.cast.nowPlaying(name: name),
                          style: theme.textTheme.bodySmall?.copyWith(height: 1.15),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: casting ? t.cast.switchToThisPhone : t.cast.switchToHost(name: name),
                    onPressed: () => remote.setCastToHost(!casting),
                    icon: Icon(casting ? Symbols.cast_connected_rounded : Symbols.smartphone_rounded),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: t.cast.playPause,
                    onPressed: () {
                      ForkMotion.selection();
                      remote.sendCommand(RemoteCommandType.playPause);
                    },
                    icon: Icon(now.playing ? Symbols.pause_rounded : Symbols.play_arrow_rounded, fill: 1),
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
