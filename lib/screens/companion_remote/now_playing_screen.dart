import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../media/ids.dart';
import '../../models/companion_remote/remote_command.dart';
import '../../providers/companion_remote_provider.dart';
import '../../utils/formatters.dart';
import '../../utils/provider_extensions.dart';
import '../../widgets/optimized_media_image.dart';

/// What the host is playing, as sent in its `nowPlaying` updates, with the
/// position carried forward between updates so the clock runs smoothly.
class HostNowPlaying {
  HostNowPlaying(this.data) : receivedAt = DateTime.now();

  final Map<String, dynamic> data;
  final DateTime receivedAt;

  String get state => data['state'] as String? ?? 'paused';
  bool get playing => state == 'playing';
  String? get serverId => data['server'] as String?;
  String get title => data['title'] as String? ?? '';
  String get subtitle => data['subtitle'] as String? ?? '';
  String? get thumb => data['thumb'] as String?;
  String? get art => data['art'] as String?;
  String? get poster => data['poster'] as String?;
  Duration get duration => Duration(milliseconds: data['durationMs'] as int? ?? 0);
  String? get marker => data['marker'] as String?;
  bool get hasNext => data['hasNext'] == true;
  bool get hasPrevious => data['hasPrevious'] == true;
  String? get audioId => data['audioId'] as String?;
  String? get subtitleId => data['subtitleId'] as String?;

  List<({String id, String label})> _tracks(String key) => [
    for (final t in (data[key] as List? ?? const []).whereType<Map>())
      (id: '${t['id']}', label: '${t['label']}'),
  ];
  List<({String id, String label})> get audio => _tracks('audio');
  List<({String id, String label})> get subtitles => _tracks('subtitles');

  Duration get position {
    final base = Duration(milliseconds: data['positionMs'] as int? ?? 0);
    final now = playing ? base + DateTime.now().difference(receivedAt) : base;
    final total = duration;
    return total > Duration.zero && now > total ? total : now;
  }

  double get progress {
    final total = duration.inMilliseconds;
    return total <= 0 ? 0 : (position.inMilliseconds / total).clamp(0.0, 1.0);
  }
}

/// Phone: full-screen controls for what the TV is playing.
class NowPlayingScreen extends StatefulWidget {
  const NowPlayingScreen({super.key});

  /// Slides up from the mini bar; swipe down (or the chevron) to close.
  static Future<void> open(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    enableDrag: true,
    builder: (_) => const FractionallySizedBox(heightFactor: 1, child: NowPlayingScreen()),
  );

  @override
  State<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends State<NowPlayingScreen> {
  late final CompanionRemoteProvider _remote = context.read<CompanionRemoteProvider>();
  HostNowPlaying? _now;
  Timer? _tick;
  double? _dragValue;

  @override
  void initState() {
    super.initState();
    _remote.nowPlaying.addListener(_onUpdate);
    _onUpdate();
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted && (_now?.playing ?? false) && _dragValue == null) setState(() {});
    });
  }

  @override
  void dispose() {
    _remote.nowPlaying.removeListener(_onUpdate);
    _tick?.cancel();
    super.dispose();
  }

  void _onUpdate() {
    final data = _remote.nowPlaying.value;
    if (data == null) {
      // Playback ended on the TV.
      if (mounted && _now != null) Navigator.of(context).maybePop();
      return;
    }
    if (mounted) setState(() => _now = HostNowPlaying(data));
  }

  void _send(RemoteCommandType type) => _remote.sendCommand(type);

  Future<void> _pickTrack(String kind, List<({String id, String label})> tracks, String? selected) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(title: Text(kind == 'audio' ? t.cast.audio : t.cast.subtitles)),
            for (final track in [if (kind == 'subtitle') (id: 'no', label: t.cast.off), ...tracks])
              ListTile(
                title: Text(track.label),
                trailing: track.id == selected ? const Icon(Symbols.check_rounded) : null,
                onTap: () => Navigator.pop(context, track.id),
              ),
          ],
        ),
      ),
    );
    if (choice != null && choice != selected) _remote.selectHostTrack(kind, choice);
  }

  Widget _artwork(HostNowPlaying now) {
    final client = context.tryGetMediaClientWithFallback(serverIdOrNull(now.serverId));
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: OptimizedMediaImage(
          client: client,
          imagePath: now.thumb ?? now.art ?? now.poster,
          width: double.infinity,
          height: double.infinity,
          fit: BoxFit.cover,
        ),
      ),
    );
  }

  Widget _controls(HostNowPlaying now) {
    final theme = Theme.of(context);
    final total = now.duration;
    final position = _dragValue == null
        ? now.position
        : Duration(milliseconds: (_dragValue! * total.inMilliseconds).round());
    final remaining = total - position;
    final audio = now.audio;
    final subtitles = now.subtitles;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(now.title, style: theme.textTheme.headlineSmall, maxLines: 2, overflow: TextOverflow.ellipsis),
        if (now.subtitle.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              now.subtitle,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        const SizedBox(height: 16),
        Slider(
          value: _dragValue ?? now.progress,
          onChanged: total > Duration.zero ? (v) => setState(() => _dragValue = v) : null,
          onChangeEnd: (v) {
            _remote.seekHostTo(Duration(milliseconds: (v * total.inMilliseconds).round()));
            // Hold the thumb where it was dropped until the TV reports back.
            _now = HostNowPlaying({
              ...now.data,
              'positionMs': (v * total.inMilliseconds).round(),
            });
            setState(() => _dragValue = null);
          },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(formatDurationTimestamp(position), style: theme.textTheme.bodySmall),
              Text('-${formatDurationTimestamp(remaining)}', style: theme.textTheme.bodySmall),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            IconButton(
              iconSize: 32,
              tooltip: t.cast.previous,
              onPressed: now.hasPrevious ? () => _send(RemoteCommandType.previousTrack) : null,
              icon: const Icon(Symbols.skip_previous_rounded, fill: 1),
            ),
            IconButton(
              iconSize: 36,
              tooltip: t.cast.back10,
              onPressed: () => _send(RemoteCommandType.seekBackward),
              icon: const Icon(Symbols.replay_10_rounded),
            ),
            IconButton.filled(
              iconSize: 44,
              onPressed: () => _send(RemoteCommandType.playPause),
              icon: now.state == 'buffering'
                  ? const SizedBox(width: 44, height: 44, child: CircularProgressIndicator(strokeWidth: 3))
                  : Icon(now.playing ? Symbols.pause_rounded : Symbols.play_arrow_rounded, fill: 1),
            ),
            IconButton(
              iconSize: 36,
              tooltip: t.cast.forward10,
              onPressed: () => _send(RemoteCommandType.seekForward),
              icon: const Icon(Symbols.forward_10_rounded),
            ),
            IconButton(
              iconSize: 32,
              tooltip: t.cast.next,
              onPressed: now.hasNext ? () => _send(RemoteCommandType.nextTrack) : null,
              icon: const Icon(Symbols.skip_next_rounded, fill: 1),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            if (now.marker != null)
              FilledButton.tonalIcon(
                onPressed: () => _send(
                  now.marker == 'credits' ? RemoteCommandType.skipCredits : RemoteCommandType.skipIntro,
                ),
                icon: const Icon(Symbols.fast_forward_rounded),
                label: Text(now.marker == 'credits' ? t.cast.skipCredits : t.cast.skipIntro),
              ),
            if (audio.length > 1)
              OutlinedButton.icon(
                onPressed: () => unawaited(_pickTrack('audio', audio, now.audioId)),
                icon: const Icon(Symbols.audiotrack_rounded),
                label: Text(audio.where((a) => a.id == now.audioId).firstOrNull?.label ?? t.cast.audio),
              ),
            if (subtitles.isNotEmpty)
              OutlinedButton.icon(
                onPressed: () => unawaited(_pickTrack('subtitle', subtitles, now.subtitleId)),
                icon: const Icon(Symbols.subtitles_rounded),
                label: Text(subtitles.where((s) => s.id == now.subtitleId).firstOrNull?.label ?? t.cast.off),
              ),
            OutlinedButton.icon(
              onPressed: () => _send(RemoteCommandType.stop),
              icon: const Icon(Symbols.stop_rounded),
              label: Text(t.cast.stop),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final now = _now;
    final name = _remote.connectedDevice?.name ?? t.companionRemote.unknownDevice;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Symbols.keyboard_arrow_down_rounded),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(t.cast.playingOn(name: name)),
      ),
      body: SafeArea(
        child: now == null
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
                          Expanded(child: Center(child: _artwork(now))),
                          const SizedBox(width: 32),
                          Expanded(child: SingleChildScrollView(child: _controls(now))),
                        ],
                      ),
                    );
                  }
                  return SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                    child: Column(children: [_artwork(now), const SizedBox(height: 24), _controls(now)]),
                  );
                },
              ),
      ),
    );
  }
}
