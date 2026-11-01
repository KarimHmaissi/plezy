import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../i18n/strings.g.dart';
import '../media/ids.dart';
import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../media/media_server_client.dart';
import '../models/companion_remote/remote_command.dart';
import '../providers/catalog_sources_provider.dart';
import '../providers/companion_remote_provider.dart';
import '../providers/multi_server_provider.dart';
import '../services/ai/ai_history.dart';
import '../services/ai/ai_remote_asks.dart';
import '../services/ai/ai_rows.dart';
import '../services/ai/claude_client.dart';
import '../services/catalog/trakt_catalog_source.dart';
import '../services/trackers/trakt/trakt_client.dart';
import '../utils/app_logger.dart';
import '../utils/platform_detector.dart';
import '../utils/snackbar_helper.dart';
import '../widgets/media_context_menu.dart' show MediaMenuExtraEntry;
import 'ai_composer.dart';

/// Fork: "Ask about this" on a film or show: the cinema composer opens over
/// the current screen with the title as context and questions about it. The
/// answer comes back as a short, spoiler-free card; questions asking for
/// recommendations also save a row of picks to the AI tab. Phones send the
/// question to the TV app they're connected to, like the AI tab does.
abstract final class AiAskAbout {
  static bool get _thinClient =>
      !PlatformDetector.isTV() &&
      (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  /// The title asked about for [item]: episodes and seasons ask about their
  /// show.
  static ({String title, int? year, MediaKind kind, String? guid})? _subject(MediaItem item) {
    final show = switch (item.kind) {
      MediaKind.episode => item.grandparentTitle,
      MediaKind.season => item.parentTitle,
      _ => null,
    };
    if (show != null && show.isNotEmpty) return (title: show, year: null, kind: MediaKind.show, guid: null);
    final title = item.title;
    if ((item.kind != MediaKind.movie && item.kind != MediaKind.show) || title == null || title.isEmpty) return null;
    return (title: title, year: item.year, kind: item.kind, guid: item.guid);
  }

  static bool supports(MediaItem item) => _subject(item) != null;

  /// The long-press menu entry; [context] is the menu's card.
  static MediaMenuExtraEntry? entryForItem(BuildContext context, MediaItem item) {
    if (!supports(item)) return null;
    return MediaMenuExtraEntry(
      icon: Symbols.question_answer_rounded,
      label: t.aiComposer.askAbout,
      onSelected: () {
        if (context.mounted) unawaited(open(context, item));
      },
    );
  }

  static Future<void> open(BuildContext context, MediaItem item) async {
    final subject = _subject(item);
    if (subject == null) return;
    CompanionRemoteProvider? remote;
    if (_thinClient) {
      remote = context.read<CompanionRemoteProvider>();
      if (!(remote.isRemote && remote.isConnected)) {
        showAppSnackBar(
          context,
          t.cast.notConnected(name: remote.connectedDevice?.name ?? t.companionRemote.unknownDevice),
        );
        return;
      }
    }
    final multi = context.read<MultiServerProvider>();
    final trakt = context
        .read<CatalogSourcesProvider?>()
        ?.connectedSources
        .whereType<TraktCatalogSource>()
        .firstOrNull
        ?.client;
    final isShow = subject.kind == MediaKind.show;
    await AiComposer.open(
      context,
      about: subject.title,
      posters: [item],
      chips: [
        (icon: Symbols.thumb_up_rounded, label: t.aiComposer.aboutWorth, request: t.aiComposer.aboutWorthRequest),
        (icon: Symbols.movie_filter_rounded, label: t.aiComposer.aboutLike, request: t.aiComposer.aboutLikeRequest),
        (icon: Symbols.groups_rounded, label: t.aiComposer.aboutCast, request: t.aiComposer.aboutCastRequest),
        (
          icon: Symbols.family_restroom_rounded,
          label: t.aiComposer.aboutScary,
          request: t.aiComposer.aboutScaryRequest,
        ),
        if (isShow)
          (icon: Symbols.start_rounded, label: t.aiComposer.aboutStart, request: t.aiComposer.aboutStartRequest),
      ],
      run: (question) {
        final request = prompt(subject, question);
        if (remote != null) return _runOnHost(remote, request);
        return _runHere(request, clientFor: multi.getClientForServer, trakt: trakt);
      },
    );
  }

  /// What the helper is asked: the question, about this title, answered in
  /// a few spoiler-free sentences; picks only when it asks for some.
  static String prompt(({String title, int? year, MediaKind kind, String? guid}) subject, String question) {
    final kind = subject.kind == MediaKind.show ? 'show' : 'film';
    final details = [kind, ?subject.year?.toString(), if (subject.guid != null) 'guid ${subject.guid}'].join(', ');
    return 'About "${subject.title}" ($details): $question\n\n'
        'Answer the question about this one title in the show_picks intro: 2-4 short, specific sentences in plain '
        'language. No spoilers (twists, deaths, endings) unless the question asks for them. Look the title up in the '
        'library first (find_titles, then get_title) and use its details (cast, summary, content rating, runtime, '
        'rating) alongside what you know. Picks: only when the question asks for recommendations (such as "anything '
        'like this?"): then pick titles from the library as usual, leaving "${subject.title}" out, and name the row in '
        'a few words that include "${subject.title}". For any other question, call show_picks with no picks.';
  }

  static Future<AiComposerOutcome> _runHere(
    String request, {
    required MediaServerClient? Function(ServerId serverId) clientFor,
    TraktClient? trakt,
  }) async {
    final result = await buildAiRow(
      request: request,
      model: ClaudeModel.sonnet,
      clientFor: clientFor,
      trakt: trakt,
      useTitle: true,
    );
    final answer = result.answer;
    if (answer.error != null) return AiComposerOutcome(error: answer.error);
    final entry = result.entry;
    if (entry != null) {
      await AiHistory.add(entry);
      AiRemoteAsks.landed.value = entry.id;
    }
    final text = (answer.intro?.trim().isNotEmpty ?? false) ? answer.intro : answer.text;
    return AiComposerOutcome(text: text, pick: entry?.items.firstOrNull);
  }

  /// Phone: the TV runs it and answers on the AI channel (`text` when there
  /// are no picks, `done` with the saved row when there are).
  static Future<AiComposerOutcome> _runOnHost(CompanionRemoteProvider remote, String request) async {
    final rid = 'about-${DateTime.now().microsecondsSinceEpoch}';
    final reply = remote.aiAnswers
        .firstWhere((d) => d['rid'] == rid && d['status'] != 'working')
        .timeout(const Duration(minutes: 3));
    remote.sendCommand(RemoteCommandType.aiAsk, data: {'rid': rid, 'request': request, 'about': true});
    try {
      final data = await reply;
      switch (data['status']) {
        case 'text':
          return AiComposerOutcome(text: data['text'] as String?);
        case 'done':
          final entry = AiHistoryEntry.fromJson(data);
          return AiComposerOutcome(text: data['text'] as String? ?? entry?.intro, pick: entry?.items.firstOrNull);
        default:
          return AiComposerOutcome(error: (data['message'] as String?) ?? t.aiTab.noPicks);
      }
    } on TimeoutException {
      return AiComposerOutcome(error: t.aiComposer.timedOut);
    } catch (e) {
      appLogger.w('AI: Ask about this failed', error: e);
      return AiComposerOutcome(error: '$e');
    }
  }
}

/// Fork: "Previously on" before carrying on with a show: a short recap of
/// everything up to the episode about to be watched, and nothing from it or
/// after. Optional (a button or menu entry), never automatic. Follow-up
/// questions from the same screen keep the same spoiler line.
abstract final class AiPreviouslyOn {
  /// The episode [item] leads into, as the line nothing may cross: the
  /// episode itself, or for a show the one Play would start. Null at the
  /// very start of a show (nothing to recap) or without episode numbers.
  static ({String show, int season, int episode, String? title})? _boundary(MediaItem item) {
    if (item.kind != MediaKind.episode) return null;
    final show = item.grandparentTitle;
    final season = item.parentIndex;
    final episode = item.index;
    if (show == null || show.isEmpty || season == null || episode == null) return null;
    if (season <= 1 && episode <= 1) return null;
    return (show: show, season: season, episode: episode, title: item.title);
  }

  static bool supports(MediaItem? nextEpisode) => nextEpisode != null && _boundary(nextEpisode) != null;

  /// The long-press entry for an episode (Continue Watching, Pick back up,
  /// episode lists).
  static MediaMenuExtraEntry? entryForItem(BuildContext context, MediaItem item) {
    if (!supports(item)) return null;
    return MediaMenuExtraEntry(
      icon: Symbols.history_edu_rounded,
      label: t.aiComposer.previouslyOn,
      onSelected: () {
        if (context.mounted) unawaited(open(context, item));
      },
    );
  }

  /// Recaps the show up to [nextEpisode], the episode about to be watched.
  static Future<void> open(BuildContext context, MediaItem nextEpisode) async {
    final boundary = _boundary(nextEpisode);
    if (boundary == null) return;
    CompanionRemoteProvider? remote;
    if (AiAskAbout._thinClient) {
      remote = context.read<CompanionRemoteProvider>();
      if (!(remote.isRemote && remote.isConnected)) {
        showAppSnackBar(
          context,
          t.cast.notConnected(name: remote.connectedDevice?.name ?? t.companionRemote.unknownDevice),
        );
        return;
      }
    }
    final multi = context.read<MultiServerProvider>();
    final trakt = context
        .read<CatalogSourcesProvider?>()
        ?.connectedSources
        .whereType<TraktCatalogSource>()
        .firstOrNull
        ?.client;
    final code = t.aiComposer.episodeCode(season: boundary.season, episode: boundary.episode);
    await AiComposer.open(
      context,
      about: '${boundary.show} · $code',
      posters: [nextEpisode],
      notesTitle: t.aiComposer.previouslyOn,
      autoRequest: t.aiComposer.recapRequest(episode: code),
      chips: [
        (icon: Symbols.short_text_rounded, label: t.aiComposer.recapShorter, request: t.aiComposer.recapShorterRequest),
        (icon: Symbols.skip_previous_rounded, label: t.aiComposer.recapLast, request: t.aiComposer.recapLastRequest),
        (icon: Symbols.groups_rounded, label: t.aiComposer.recapWho, request: t.aiComposer.recapWhoRequest),
      ],
      run: (question) {
        final request = prompt(boundary, question);
        if (remote != null) return AiAskAbout._runOnHost(remote, request);
        return AiAskAbout._runHere(request, clientFor: multi.getClientForServer, trakt: trakt);
      },
    );
  }

  /// The spoiler line is spelt out in every request, follow-ups included.
  static String prompt(({String show, int season, int episode, String? title}) b, String question) {
    final next = 'season ${b.season}, episode ${b.episode}${b.title == null ? '' : ' ("${b.title}")'}';
    final last = b.episode > 1 ? 'season ${b.season}, episode ${b.episode - 1}' : 'the end of season ${b.season - 1}';
    return 'Previously on "${b.show}" (show). The user is about to watch $next and asks: $question\n\n'
        'SPOILER LINE: they have seen everything up to and including $last, and nothing after it. Say nothing at all '
        'about $next or anything later: no events, deaths, reveals, returning or new characters, guest stars, '
        'relationships, titles or hints of what is coming, and no "this will matter later". If you are not sure '
        'whether something happens before or after the line, leave it out. Do not guess at plot you are unsure of; '
        'say less instead.\n'
        'Answer in the show_picks intro, in plain sentences in order of events, focusing on where things stand going '
        'into $next (a recap is about 5-8 short sentences unless asked otherwise). Call show_picks with no picks.';
  }
}
