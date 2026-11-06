// ignore_for_file: invalid_annotation_target
import 'package:freezed_annotation/freezed_annotation.dart';

import '../../utils/json_converters.dart';

part 'remote_command.freezed.dart';
part 'remote_command.g.dart';

enum RemoteCommandType {
  dpadUp,
  dpadDown,
  dpadLeft,
  dpadRight,
  select,
  back,
  contextMenu,

  play,
  pause,
  playPause,
  stop,
  seekForward,
  seekBackward,
  nextTrack,
  previousTrack,
  skipIntro,
  skipCredits,

  volumeUp,
  volumeDown,
  volumeMute,
  volumeSet,

  tabNext,
  tabPrevious,
  tabDiscover,
  tabLibraries,
  tabSearch,
  tabDownloads,
  tabSettings,

  home,
  search,
  subtitles,
  audioTracks,
  qualitySettings,
  fullscreen,

  ping,
  pong,
  deviceInfo,
  disconnect,
  ack,
  syncState,

  /// Fork: run an AI request on the host (its key, index and saved answers).
  /// Data: `rid` (the phone's request id), `request`.
  aiAsk,

  /// Fork, casting: play a title on the host. Data: `server`, `id`, `title`,
  /// and `offsetMs` for an explicit position (else it resumes as usual).
  playMedia,

  /// Fork, casting: show a title's detail page on the host (`server`, `id`).
  openItem,

  /// Fork, casting: the host's answer to [playMedia] / [openItem]
  /// (`ok`, `message`).
  castResult,

  /// Fork: the host's progress and picks for an [aiAsk]. Data: `rid`,
  /// `status` (working / done / error), and when done `id`, `title`, `intro`,
  /// `picks` (each `item` as MediaItem JSON plus `reason`); `message` on error.
  aiAnswer,

  /// Fork, now playing: the host's player state, sent on change and about
  /// once a second while playing. Data: `state` (playing / paused /
  /// buffering / stopped), `server`, `id`, `title`, `subtitle`, `thumb`,
  /// `art`, `positionMs`, `durationMs`, `audio` / `subtitles` (lists of
  /// `{id, label}`), `audioId`, `subtitleId`, `marker` (intro / credits),
  /// `hasNext`, `hasPrevious`.
  nowPlaying,

  /// Fork, now playing: seek the host's player to `positionMs`.
  seekTo,

  /// Fork, now playing: pick a track on the host. Data: `kind` (audio /
  /// subtitle), `id` (from [nowPlaying]'s lists).
  selectTrack,

  /// Fork, mirror: the phone asks for the host's customisation data.
  mirrorRequest,

  /// Fork, mirror: the host's customisation data (`rev`, `data`: an export
  /// document), sent on [mirrorRequest] and after every change.
  mirrorSnapshot,

  /// Fork, mirror: an edit made on the phone, for the host to apply. Data:
  /// `op` (setting / home / comfort) and its fields.
  mirrorWrite,

  /// Fork, mirror: run an AI row action on the host. Data: `action`
  /// (findMore / refresh), `id` (the saved answer).
  aiAction,

  /// Fork, mirror: the host's running AI requests (`running`, `labels`).
  aiActivity,

  /// Fork, catch-up sync: a phone working on its own data offers when each
  /// piece last changed (`stamps`: unit → [ms, deleted]).
  catchUpOffer,

  /// Fork, catch-up sync: the host's pieces that are newer than the phone's
  /// (`units`) and the units it wants from the phone (`want`).
  catchUpReply,

  /// Fork, catch-up sync: the phone's newer pieces the host asked for
  /// (`units`).
  catchUpPush,

  /// Fork, catch-up sync: the host's data changed while a phone is
  /// connected; the phone answers with a new [catchUpOffer].
  catchUpNudge,

  /// Fork, The Reel (On TV mode): show the host's Reel tab.
  tabReel,

  /// Fork, The Reel: open a deck on the host (`deck`, optional); the host
  /// answers with a [reelState].
  reelOpen,

  /// Fork, The Reel: next or previous card on the host (`dir`: 1 / -1), or
  /// another deck (`deckDir`: 1 / -1).
  reelStep,

  /// Fork, The Reel: act on the host's current card (`action`: watch / save /
  /// notForMe / pause / replay).
  reelAction,

  /// Fork, The Reel: the host's card on every change. Data: `active`, `deck`,
  /// `deckName`, `decks` (`{id, name}`), `index`, `groupKey`, `card` and
  /// `next` (each `{id, title, year, server, art, thumb}`, image paths only),
  /// `playing`, `poolEnd`.
  reelState,
}

class _RemoteCommandTypeConverter extends IndexedEnumConverter<RemoteCommandType> {
  const _RemoteCommandTypeConverter() : super(RemoteCommandType.values, RemoteCommandType.ping);
}

@freezed
sealed class RemoteCommand with _$RemoteCommand {
  const factory RemoteCommand({
    @JsonKey(name: 't') @_RemoteCommandTypeConverter() required RemoteCommandType type,
    @JsonKey(name: 'd') Map<String, dynamic>? data,
  }) = _RemoteCommand;

  factory RemoteCommand.fromJson(Map<String, dynamic> json) => _$RemoteCommandFromJson(json);
}
