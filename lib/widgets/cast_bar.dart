import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../i18n/strings.g.dart';
import '../providers/companion_remote_provider.dart';
import '../utils/snackbar_helper.dart';

/// Phone side of casting: while connected to a TV app, shows where Play goes
/// (the TV, or this phone with one tap) and what the TV last started.
class CastBar extends StatefulWidget {
  const CastBar({super.key});

  @override
  State<CastBar> createState() => _CastBarState();
}

class _CastBarState extends State<CastBar> {
  CompanionRemoteProvider? _remote;
  String? _nowPlaying;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final remote = context.read<CompanionRemoteProvider?>();
    if (identical(remote, _remote)) return;
    _remote?.castResults.removeListener(_onResult);
    _remote = remote;
    remote?.castResults.addListener(_onResult);
  }

  @override
  void dispose() {
    _remote?.castResults.removeListener(_onResult);
    super.dispose();
  }

  void _onResult() {
    final result = _remote?.castResults.value;
    if (result == null || !mounted) return;
    if (result.ok) {
      setState(() => _nowPlaying = result.message);
    } else {
      showAppSnackBar(context, t.cast.failed(message: result.message));
    }
  }

  @override
  Widget build(BuildContext context) {
    final remote = context.watch<CompanionRemoteProvider?>();
    if (remote == null || !remote.isRemote || !remote.isConnected) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final name = remote.connectedDevice?.name ?? t.companionRemote.unknownDevice;
    final casting = remote.castToHost;
    return Material(
      color: casting ? theme.colorScheme.primaryContainer : theme.colorScheme.surfaceContainerHighest,
      child: InkWell(
        onTap: () => remote.setCastToHost(!casting),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(casting ? Symbols.cast_connected_rounded : Symbols.smartphone_rounded, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      casting ? t.cast.playingOn(name: name) : t.cast.thisPhone,
                      style: theme.textTheme.labelLarge,
                    ),
                    if (casting && _nowPlaying != null)
                      Text(
                        '${t.cast.nowPlaying(name: name)}: $_nowPlaying',
                        style: theme.textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
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
}
