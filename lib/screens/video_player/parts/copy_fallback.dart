part of '../../video_player_screen.dart';

/// Fork: one launch's walk through the copies of its title after an open
/// failed before its first frame. Created at the first sign of trouble (a
/// 503, the server's switch away from a missing version, a failed open) and
/// dropped at the first frame.
class _CopyFallbackRun {
  _CopyFallbackRun({required this.origin, required this.referenceHeight, required this.resumePosition});

  /// The item the viewer opened; the copy lookup asks for its title.
  final MediaItem origin;

  /// Height of the version the viewer asked for: "the same quality" first.
  final int? referenceHeight;

  /// Where the viewer's open would have started, carried to every copy:
  /// another server keeps its own watch state for its copy.
  final Duration? resumePosition;

  /// [CopySource.key]s already opened or failed in this run.
  final Set<String> tried = {};

  /// Servers that failed a file in this run; a fresh server goes first.
  final Set<String> failedServerIds = {};

  /// Items this run opened, so a failure of any of them continues the run.
  final Set<String> itemKeys = {};

  /// Copies opened after the first, the server's own version switch included.
  int attempts = 0;

  /// The other copies of [origin], once asked for.
  Future<List<MediaItem>>? copies;

  /// The most recent failure, presented if no copy is left.
  ({PlaybackFailureAction action, String? cause, String message})? lastFailure;

  /// The file that failed most recently.
  CopySource? lastFailed;

  /// Why the most recent file failed, for the next log line.
  CopyFallbackReason? lastReason;

  final List<String?> _servers = [];

  /// The server's number in this run (0 = the first one met), for log lines
  /// that must not name it.
  int serverIndex(String? serverId) {
    final index = _servers.indexOf(serverId);
    if (index >= 0) return index;
    _servers.add(serverId);
    return _servers.length - 1;
  }

  void markTried(CopySource source) {
    tried.add(source.key);
    itemKeys.add(source.copy.globalKey);
    serverIndex(source.copy.serverId);
  }

  /// [source] failed. It is remembered ([BrokenCopies]) so Play's default
  /// and later fallbacks skip it for a while, unless it was only skipped for
  /// failing before: that must not keep it remembered for ever.
  void markFailed(CopySource source, CopyFallbackReason reason) {
    markTried(source);
    final serverId = source.copy.serverId;
    if (serverId != null) failedServerIds.add(serverId);
    lastFailed = source;
    lastReason = reason;
    if (reason != CopyFallbackReason.remembered) unawaited(BrokenCopies.instance.markBroken(source.key));
  }
}

extension _VideoPlayerCopyFallbackMethods on VideoPlayerScreenState {
  /// Whether an open failing right now may move on to another copy by itself.
  bool get _copyFallbackAppliesNow => copyFallbackApplies(
    isLive: widget.isLive,
    isPlexBacked: _currentMetadata.backend == MediaBackend.plex,
    isLocalPlayback: _isOfflinePlayback,
    firstFrameRendered: _firstFrame.rendered,
    inWatchTogetherRoom: _watchTogetherRoom()?.isConnected ?? false,
    strictMediaSelection: widget.strictMediaSelection,
  );

  /// Whether a failure surface may offer "Choose another copy".
  bool get _offersCopyChoice => copyFallbackApplies(
    isLive: widget.isLive,
    isPlexBacked: _currentMetadata.backend == MediaBackend.plex,
    isLocalPlayback: _isOfflinePlayback,
    firstFrameRendered: false,
    inWatchTogetherRoom: _watchTogetherRoom()?.isConnected ?? false,
    strictMediaSelection: false,
  );

  /// The versions known for [_currentMetadata]: the committed session's (they
  /// carry the server's file check) when it describes this item.
  MediaItem _currentItemWithVersions() {
    final session = _playbackSession;
    if (session != null &&
        session.metadata.globalKey == _currentMetadata.globalKey &&
        session.availableVersions.isNotEmpty) {
      return _currentMetadata.copyWith(mediaVersions: session.availableVersions);
    }
    return _currentMetadata;
  }

  /// The file the current open asked for.
  CopySource _requestedCopySource() {
    final item = _currentItemWithVersions();
    final request = _currentOpenRequest;
    final versions = item.mediaVersions ?? const <MediaVersion>[];
    var index = request?.mediaIndex ?? _effectiveSelectedMediaIndex;
    final sourceId = request?.mediaSourceId;
    if (sourceId != null) {
      final byId = versions.indexWhere((v) => v.id == sourceId);
      if (byId >= 0) index = byId;
    }
    return CopySource(item, index);
  }

  /// The file the current open is actually on: the committed session's
  /// version when it describes this item (the server may have switched away
  /// from the one asked for), else the one asked for.
  CopySource _currentCopySource() {
    final session = _playbackSession;
    if (session != null && session.metadata.globalKey == _currentMetadata.globalKey) {
      return CopySource(_currentItemWithVersions(), session.mediaIndex);
    }
    return _requestedCopySource();
  }

  /// The run for the item on screen: the one in progress when this item is
  /// one of its copies, else a new one.
  _CopyFallbackRun _copyFallbackRunForCurrent() {
    final run = _copyFallback;
    if (run != null && run.itemKeys.contains(_currentMetadata.globalKey)) return run;
    final requested = _requestedCopySource();
    final viewOffsetMs = _currentMetadata.viewOffsetMs ?? 0;
    final created = _CopyFallbackRun(
      origin: _currentMetadata,
      referenceHeight: requested.height,
      resumePosition:
          _currentOpenRequest?.resumePosition ?? Duration(milliseconds: viewOffsetMs > 0 ? viewOffsetMs : 0),
    );
    created.itemKeys.add(_currentMetadata.globalKey);
    created.serverIndex(_currentMetadata.serverId);
    return _copyFallback = created;
  }

  /// Ask every online server for the title's copies, once per run, so they
  /// are at hand when the open gives up. Bounded; an error lists none.
  void _startCopyLookup(_CopyFallbackRun run) {
    if (run.copies != null) return;
    final MultiServerProvider multi;
    try {
      multi = context.read<MultiServerProvider>();
    } catch (_) {
      run.copies = Future.value(const <MediaItem>[]);
      return;
    }
    final lookup = TitleCopies.from(multi.aggregationService).forItem(run.origin);
    if (lookup == null) {
      run.copies = Future.value(const <MediaItem>[]);
      return;
    }
    run.copies = () async {
      try {
        return (await lookup.timeout(copyPickerLookupPatience)).items;
      } catch (e) {
        appLogger.d('[CopyFallback] copy lookup failed', error: e);
        return const <MediaItem>[];
      }
    }();
  }

  /// The open may be in trouble (a 503 before the first frame): start looking
  /// for the other copies now, so a fallback does not wait for them later.
  void _primeCopyFallback() {
    if (!_copyFallbackAppliesNow) return;
    _startCopyLookup(_copyFallbackRunForCurrent());
  }

  /// The session [session] about to be committed opened another version than
  /// the one asked for because the server's file check flagged it missing
  /// ([resolvePlexPlaybackSelection]'s quiet fallback). Count it as an
  /// attempt, say so, and look for the other copies in case this one fails
  /// too.
  void _noteServerVersionSwitch(PlaybackSession session) {
    final request = _currentOpenRequest;
    if (request == null || request.metadata.globalKey != session.metadata.globalKey) return;
    final versions = session.availableVersions;
    if (versions.length < 2) return;
    var requested = request.mediaIndex ?? -1;
    final sourceId = request.mediaSourceId;
    if (sourceId != null) {
      final byId = versions.indexWhere((v) => v.id == sourceId);
      if (byId >= 0) requested = byId;
    }
    if (requested < 0 || requested >= versions.length || requested == session.mediaIndex) return;
    if (versions[requested].isPlayable || !_copyFallbackAppliesNow) return;
    final item = session.metadata.copyWith(mediaVersions: versions);
    final from = CopySource(item, requested);
    final to = CopySource(item, session.mediaIndex);
    final run = _copyFallbackRunForCurrent();
    run.markFailed(from, CopyFallbackReason.missing);
    run.markTried(to);
    run.attempts++;
    appLogger.w(
      copyFallbackLogLine(
        reason: CopyFallbackReason.missing,
        attempt: run.attempts,
        from: from,
        to: to,
        serverIndex: run.serverIndex,
      ),
    );
    // A default about to be skipped for failing recently gets its own
    // notice from the skip; one here would only flash past.
    if (!(widget.defaultCopyChoice && BrokenCopies.instance.isBroken(to.key))) {
      _showCopyFallbackNotice(from: from, to: to);
    }
    _startCopyLookup(run);
  }

  /// "That copy wouldn't play — trying the 1080p copy on Server B".
  void _showCopyFallbackNotice({required CopySource from, required CopySource to}) {
    final otherServer = to.copy.serverId != from.copy.serverId;
    final location = otherServer && to.copy.serverName != null ? to.copy.serverName! : copyLocationLabel(to.copy);
    final quality = copySourceQualityLabel(to);
    final text = _copyFallback?.lastReason == CopyFallbackReason.remembered
        ? quality == null
              ? t.copies.skippingRememberedAnother(location: location)
              : t.copies.skippingRemembered(quality: quality, location: location)
        : quality == null
        ? t.copies.tryingAnother(location: location)
        : t.copies.trying(quality: quality, location: location);
    _toastController.show(Symbols.swap_horiz_rounded, text, duration: const Duration(seconds: 4));
  }

  /// A failed open, before its first frame, that another copy may fix. Takes
  /// the failure over and returns true when there are attempts left; the
  /// caller's own handling runs otherwise. The dead open is stopped here, but
  /// the launch is not marked failed: the next copy continues it.
  bool _tryCopyFallback({
    required CopyFallbackReason reason,
    required PlaybackFailureAction action,
    String? cause,
    required String message,
  }) {
    if (!_copyFallbackAppliesNow) return false;
    final run = _copyFallbackRunForCurrent();
    run.markFailed(_currentCopySource(), reason);
    run.lastFailure = (action: action, cause: cause, message: message);
    if (run.attempts >= maxCopyFallbackAttempts) {
      appLogger.w('[CopyFallback] gave up after ${run.attempts} attempt(s) reason=${reason.name}');
      return false;
    }
    _hasFatalPlaybackError = true;
    _progressTracker?.stopTracking();
    _abortCurrentOpen('copy fallback');
    final currentPlayer = player;
    if (currentPlayer != null) {
      unawaited(
        currentPlayer.stop().catchError((Object e, StackTrace st) {
          appLogger.w('Failed to stop the failed load', error: e, stackTrace: st);
        }),
      );
    }
    _startCopyLookup(run);
    unawaited(_continueCopyFallback(run));
    return true;
  }

  /// Open the next copy of [run], until one opens or none is left.
  Future<void> _continueCopyFallback(_CopyFallbackRun run) async {
    final copies = await run.copies!;
    while (true) {
      if (!mounted || _shuttingDown || _isExiting.value || !identical(_copyFallback, run)) return;
      final next = run.attempts >= maxCopyFallbackAttempts ? null : _nextCopyCandidate(run, copies);
      if (next == null) {
        appLogger.w('[CopyFallback] gave up after ${run.attempts} attempt(s): no other copy left');
        _presentCopyFallbackFailure(run);
        return;
      }
      run.attempts++;
      run.markTried(next);
      final from = run.lastFailed ?? next;
      appLogger.w(
        copyFallbackLogLine(
          reason: run.lastReason ?? CopyFallbackReason.openFailed,
          attempt: run.attempts,
          from: from,
          to: next,
          serverIndex: run.serverIndex,
        ),
      );
      _showCopyFallbackNotice(from: from, to: next);
      final outcome = await _openCopyInPlace(run, next, reason: 'copy fallback');
      if (!mounted) return;
      switch (outcome) {
        // Opening; its own failure comes back through _onPlayerError.
        case MediaReloadOutcome.opened:
        // A newer transition (Back, another item) owns the player now.
        case MediaReloadOutcome.superseded:
          return;
        // Another transition held the player, so nothing was opened: the
        // failure stays on screen rather than a spinner with nothing behind.
        case MediaReloadOutcome.rejected:
          _presentCopyFallbackFailure(run);
          return;
        // The server would not even hand over this copy: the next one.
        case MediaReloadOutcome.failed:
          run.markFailed(next, CopyFallbackReason.openFailed);
      }
    }
  }

  /// The best file of [run] not yet tried, among the item on screen (with
  /// its checked versions) and the copies found on every server; only Plex
  /// copies on servers that are online.
  CopySource? _nextCopyCandidate(_CopyFallbackRun run, List<MediaItem> copies) {
    final MultiServerManager manager;
    try {
      manager = context.read<MultiServerProvider>().serverManager;
    } catch (_) {
      return null;
    }
    bool reachable(MediaItem copy) {
      final id = serverIdOrNull(copy.serverId);
      return copy.backend == MediaBackend.plex && id != null && manager.isClientOnline(id);
    }

    final ordered = orderCopyFallbacks(
      copies: [_currentItemWithVersions(), run.origin, ...copies].where(reachable),
      referenceHeight: run.referenceHeight,
      tried: run.tried,
      failedServerIds: run.failedServerIds,
      isRemembered: (source) => BrokenCopies.instance.isBroken(source.key),
    );
    return ordered.isEmpty ? null : ordered.first;
  }

  /// Open [source] in place of the failed file, keeping where the viewer
  /// would have started, their audio and subtitle choices (by language, since
  /// another file's streams have other ids) and the quality preset.
  Future<MediaReloadOutcome> _openCopyInPlace(_CopyFallbackRun run, CopySource source, {required String reason}) {
    final version = source.version;
    _fatalHttpStatuses.clear();
    return _reloadMediaInPlace(
      metadata: source.copy,
      selectedMediaIndex: source.versionIndex,
      selectedMediaSourceId: version == null || version.id.isEmpty ? null : version.id,
      qualityPreset: _currentOpenRequest?.qualityPreset ?? _selectedQualityPreset,
      useCurrentAudioStreamSelection: false,
      resumePosition: run.resumePosition,
      preserveCurrentTrackSelection: true,
      preservedAudioTrack: _sessionAudioPreference ?? _preferredAudioTrack,
      preservedSubtitleTrack: _sessionSubtitlePreference ?? _preferredSubtitleTrack,
      preservedSecondarySubtitleTrack: _sessionSecondarySubtitlePreference ?? _preferredSecondarySubtitleTrack,
      showErrorUi: false,
      reason: reason,
    );
  }

  /// No copy is left: the failure surface the last failure calls for, with
  /// "Choose another copy" on it.
  void _presentCopyFallbackFailure(_CopyFallbackRun run) {
    final failure = run.lastFailure;
    final action = failure?.action ?? PlaybackFailureAction.fatal;
    switch (action) {
      case PlaybackFailureAction.serverBusyDialog:
        _latchFatalPlaybackError(action);
        unawaited(_showServerBusyDialog());
      case PlaybackFailureAction.mediaUnreadableDialog:
        _latchFatalPlaybackError(action);
        unawaited(_showMediaUnreadableDialog());
      default:
        _latchFatalPlaybackError(PlaybackFailureAction.fatal, cause: failure?.cause);
        _presentPlaybackFailure(failure?.message ?? t.messages.playbackFailed);
    }
  }

  /// "Choose another copy": the copy picker over the player, listing every
  /// file of the title on every online Plex server, the ones that failed in
  /// this run marked. The pick opens in place; one that fails comes back to
  /// a failure surface instead of moving on by itself. Returns false when the
  /// viewer dismissed the picker.
  Future<bool> _chooseAnotherCopy() async {
    final run = _copyFallbackRunForCurrent();
    _startCopyLookup(run);
    final copies = await run.copies!;
    if (!mounted || _shuttingDown) return false;
    final picked = await showCopyPicker(
      context,
      item: run.origin,
      copies: [_currentItemWithVersions(), run.origin, ...copies],
      didNotPlay: (source) => copySourceWasTried(source, run.tried) || BrokenCopies.instance.isBroken(source.key),
      include: (source) => source.copy.backend == MediaBackend.plex,
    );
    if (picked == null || !mounted || _shuttingDown) return false;
    _dismissPlaybackFailure();
    run.attempts = maxCopyFallbackAttempts;
    run.markTried(picked);
    appLogger.i(
      '[CopyFallback] chosen by hand: ${copySourceQualityLabel(picked) ?? '?'}@s${run.serverIndex(picked.copy.serverId)}',
    );
    final outcome = await _openCopyInPlace(run, picked, reason: 'copy chosen after failure');
    if (!mounted) return true;
    if (outcome == MediaReloadOutcome.failed || outcome == MediaReloadOutcome.rejected) {
      if (outcome == MediaReloadOutcome.failed) run.markFailed(picked, CopyFallbackReason.openFailed);
      _presentCopyFallbackFailure(run);
    }
    return true;
  }

  /// Play's default landed on a file that failed to play recently (every
  /// version of this copy did, or the server switched to one that did):
  /// open the title's best other copy instead, when one has not failed too.
  /// Returns true when the fallback took the open over. Only for Play's own
  /// default ([VideoPlayerScreen.defaultCopyChoice]): a version picked or
  /// remembered by hand is opened as asked.
  Future<bool> _skipRememberedBrokenCopy() async {
    if (!widget.defaultCopyChoice || !_copyFallbackAppliesNow) return false;
    final current = _currentCopySource();
    if (!BrokenCopies.instance.isBroken(current.key)) return false;
    final run = _copyFallbackRunForCurrent();
    _startCopyLookup(run);
    final copies = await run.copies!;
    if (!mounted || _shuttingDown || !identical(_copyFallback, run)) return false;
    run.markTried(current);
    final next = _nextCopyCandidate(run, copies);
    if (next == null || BrokenCopies.instance.isBroken(next.key)) {
      // Nothing better: open it as asked, and let a failure move on.
      return false;
    }
    run.markFailed(current, CopyFallbackReason.remembered);
    run.lastFailure = (action: PlaybackFailureAction.fatal, cause: null, message: t.messages.playbackFailed);
    _hasFatalPlaybackError = true;
    _abortCurrentOpen('copy fallback: skipping a copy that failed recently');
    unawaited(_continueCopyFallback(run));
    return true;
  }

  /// The first frame of a file is on screen: a run that got here worked.
  /// The file playing is forgotten as broken ([BrokenCopies]), whether or
  /// not a run brought it here.
  void _onCopyFallbackFirstFrame() {
    if (!widget.isLive && !_isOfflinePlayback) {
      unawaited(BrokenCopies.instance.clear(_currentCopySource().key));
    }
    final run = _copyFallback;
    if (run == null) return;
    if (run.attempts > 0 && run.itemKeys.contains(_currentMetadata.globalKey)) {
      final playing = _currentCopySource();
      appLogger.i(
        '[CopyFallback] playing ${copySourceQualityLabel(playing) ?? '?'}@s${run.serverIndex(playing.copy.serverId)} '
        'after ${run.attempts} attempt(s)',
      );
    }
    _copyFallback = null;
  }
}
