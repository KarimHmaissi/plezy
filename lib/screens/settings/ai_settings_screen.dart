import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';

import '../../providers/catalog_sources_provider.dart';
import '../../services/companion_remote/phone_mode.dart';
import '../../services/ai/ai_eval.dart';
import '../../services/ai/ai_key_receiver.dart';
import '../../services/ai/ai_spend.dart';
import '../../services/ai/ai_home_refresher.dart';
import '../../services/ai/claude_client.dart';
import '../../services/catalog/trakt_catalog_source.dart';
import '../../services/library_index/library_index.dart';
import 'ai_try_screen.dart';
import '../../services/ai/ai_key_store.dart';
import '../../services/tmdb/tmdb_key_store.dart';
import '../../utils/dialogs.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/focused_scroll_scaffold.dart';

/// Settings ▸ AI: the Anthropic API key and the TMDB key (each pasted in or
/// sent from another device, checked, stored encrypted on this device), and
/// which models the helper uses. For You's note and rebuild live on the
/// Reel's settings page (ReelForYouTiles).
class AiSettingsScreen extends StatefulWidget {
  const AiSettingsScreen({super.key});

  @override
  State<AiSettingsScreen> createState() => _AiSettingsScreenState();
}

class _AiSettingsScreenState extends State<AiSettingsScreen> {
  String? _keyHint;
  String? _tmdbHint;

  /// The last TMDB check on this screen, shown next to the key.
  AiKeyCheck? _tmdbCheck;
  bool _loaded = false;
  bool _busy = false;
  bool _autoRefresh = true;
  String? _autoRefreshStatus;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final key = await AiKeyStore.read();
    final tmdbKey = await TmdbKeyStore.read();
    final autoRefresh = await AiHomeRefresher.enabled();
    if (!mounted) return;
    setState(() {
      _keyHint = key == null ? null : AiKeyStore.hint(key);
      _tmdbHint = tmdbKey == null ? null : TmdbKeyStore.hint(tmdbKey);
      _autoRefresh = autoRefresh;
      _loaded = true;
    });
  }

  String _message(AiKeyCheck check) => switch (check) {
    AiKeyCheck.ok => t.ai.keyWorks,
    AiKeyCheck.invalid => t.ai.keyRejected,
    AiKeyCheck.unreachable => t.ai.keyUnreachable,
  };

  String _tmdbMessage(AiKeyCheck check) => switch (check) {
    AiKeyCheck.ok => t.ai.tmdbKeyWorks,
    AiKeyCheck.invalid => t.ai.tmdbKeyRejected,
    AiKeyCheck.unreachable => t.ai.tmdbKeyUnreachable,
  };

  String _tmdbStatus(AiKeyCheck check) => switch (check) {
    AiKeyCheck.ok => t.ai.tmdbKeyStatusWorks,
    AiKeyCheck.invalid => t.ai.tmdbKeyStatusRejected,
    AiKeyCheck.unreachable => t.ai.tmdbKeyStatusUnreachable,
  };

  Future<void> _paste() async {
    final key = await showTextInputDialog(
      context,
      title: t.ai.pasteKey,
      labelText: t.ai.keyLabel,
      hintText: 'sk-ant-…',
      confirmText: t.common.save,
      obscureText: true,
      validator: (v) => v.trim().startsWith('sk-ant-') ? null : t.ai.keyFormat,
    );
    if (key == null || !mounted) return;
    setState(() => _busy = true);
    final check = await AiKeyStore.check(key);
    if (check == AiKeyCheck.invalid) {
      if (mounted) {
        setState(() => _busy = false);
        showErrorSnackBar(context, _message(check));
      }
      return;
    }
    // Saved even when Anthropic can't be reached right now; it's checked
    // again on first use.
    await AiKeyStore.write(key);
    if (!mounted) return;
    setState(() => _busy = false);
    await _load();
    if (!mounted) return;
    check == AiKeyCheck.ok
        ? showSuccessSnackBar(context, _message(check))
        : showErrorSnackBar(context, _message(check));
  }

  /// Open a one-time page on the local network so the key can be pasted on
  /// a phone or laptop instead of typed with the remote.
  Future<void> _receive({KeyReceiverKind kind = KeyReceiverKind.anthropic}) async {
    final isTmdb = identical(kind, KeyReceiverKind.tmdb);
    final receiver = await AiKeyReceiver.start(kind: kind);
    if (!mounted) return;
    if (receiver == null) {
      showErrorSnackBar(context, t.ai.receiveNoNetwork);
      return;
    }
    final dialog = showScopedDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(t.ai.receiveTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.ai.receiveStep1),
            const SizedBox(height: 8),
            SelectableText(receiver.address, style: Theme.of(dialogContext).textTheme.headlineSmall),
            const SizedBox(height: 16),
            Text(t.ai.receiveStep2),
            const SizedBox(height: 8),
            Text(receiver.code, style: Theme.of(dialogContext).textTheme.displaySmall?.copyWith(letterSpacing: 6)),
            const SizedBox(height: 16),
            Text(t.ai.receiveExpiry, style: Theme.of(dialogContext).textTheme.bodySmall),
          ],
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () {
              receiver.cancel();
              Navigator.of(dialogContext).pop();
            },
            child: Text(t.common.cancel),
          ),
        ],
      ),
    );
    final result = await receiver.result;
    if (!mounted) return;
    if (result != AiKeyReceiveResult.cancelled) Navigator.of(context, rootNavigator: true).maybePop();
    await dialog;
    await _load();
    if (!mounted) return;
    // A rejected key isn't saved, so the stored key's status stays as it was.
    if (isTmdb && result == AiKeyReceiveResult.saved) setState(() => _tmdbCheck = AiKeyCheck.ok);
    if (isTmdb && result == AiKeyReceiveResult.savedUnchecked) {
      setState(() => _tmdbCheck = AiKeyCheck.unreachable);
    }
    final message = isTmdb ? _tmdbMessage : _message;
    switch (result) {
      case AiKeyReceiveResult.saved:
        showSuccessSnackBar(context, message(AiKeyCheck.ok));
      case AiKeyReceiveResult.savedUnchecked:
        showErrorSnackBar(context, message(AiKeyCheck.unreachable));
      case AiKeyReceiveResult.rejected:
        showErrorSnackBar(context, message(AiKeyCheck.invalid));
      case AiKeyReceiveResult.tooManyAttempts:
        showErrorSnackBar(context, t.ai.receiveTooManyAttempts);
      case AiKeyReceiveResult.timedOut:
        showErrorSnackBar(context, t.ai.receiveTimedOut);
      case AiKeyReceiveResult.cancelled:
        break;
    }
  }

  String? _evalStatus;

  Future<void> _try() async {
    final request = await showTextInputDialog(
      context,
      title: t.ai.tryRequest,
      labelText: t.ai.tryRequestLabel,
      confirmText: t.ai.ask,
    );
    if (request == null || request.trim().isEmpty || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AiTryScreen(request: request.trim())));
    if (mounted) setState(() {});
  }

  Future<void> _eval() async {
    final trakt = context.read<CatalogSourcesProvider?>()?.connectedSources.whereType<TraktCatalogSource>().firstOrNull;
    setState(() => _evalStatus = 'Starting…');
    try {
      final path = await AiEval.run(
        index: LibraryIndex.instance,
        trakt: trakt?.client,
        models: const [ClaudeModel.sonnet],
        onProgress: (p) {
          if (mounted) setState(() => _evalStatus = 'Running $p');
        },
      );
      if (mounted) setState(() => _evalStatus = 'Done: $path');
    } catch (e) {
      if (mounted) setState(() => _evalStatus = 'Done (failed): $e');
    }
  }

  Future<void> _test() async {
    final key = await AiKeyStore.read();
    if (key == null) return;
    setState(() => _busy = true);
    final check = await AiKeyStore.check(key);
    if (!mounted) return;
    setState(() => _busy = false);
    check == AiKeyCheck.ok
        ? showSuccessSnackBar(context, _message(check))
        : showErrorSnackBar(context, _message(check));
  }

  Future<void> _remove() async {
    final confirmed = await showConfirmDialog(
      context,
      title: t.ai.removeKeyTitle,
      message: t.ai.removeKeyMessage,
      confirmText: t.ai.removeKey,
      isDestructive: true,
    );
    if (!confirmed) return;
    await AiKeyStore.remove();
    await _load();
  }

  Future<void> _pasteTmdb() async {
    final key = await showTextInputDialog(
      context,
      title: t.ai.tmdbPasteKey,
      labelText: t.ai.tmdbKeyLabel,
      confirmText: t.common.save,
      obscureText: true,
      validator: (v) => TmdbKeyStore.looksValid(v) ? null : t.ai.tmdbKeyFormat,
    );
    if (key == null || !mounted) return;
    setState(() => _busy = true);
    final check = await TmdbKeyStore.check(key);
    if (check == AiKeyCheck.invalid) {
      if (mounted) {
        setState(() => _busy = false);
        showErrorSnackBar(context, _tmdbMessage(check));
      }
      return;
    }
    // Saved even when TMDB can't be reached right now; it's checked again on
    // first use.
    await TmdbKeyStore.write(key);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _tmdbCheck = check;
    });
    await _load();
    if (!mounted) return;
    check == AiKeyCheck.ok
        ? showSuccessSnackBar(context, _tmdbMessage(check))
        : showErrorSnackBar(context, _tmdbMessage(check));
  }

  Future<void> _testTmdb() async {
    final key = await TmdbKeyStore.read();
    if (key == null) return;
    setState(() => _busy = true);
    final check = await TmdbKeyStore.check(key);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _tmdbCheck = check;
    });
    check == AiKeyCheck.ok
        ? showSuccessSnackBar(context, _tmdbMessage(check))
        : showErrorSnackBar(context, _tmdbMessage(check));
  }

  Future<void> _removeTmdb() async {
    final confirmed = await showConfirmDialog(
      context,
      title: t.ai.tmdbRemoveKeyTitle,
      message: t.ai.tmdbRemoveKeyMessage,
      confirmText: t.ai.tmdbRemoveKey,
      isDestructive: true,
    );
    if (!confirmed) return;
    await TmdbKeyStore.remove();
    if (mounted) setState(() => _tmdbCheck = null);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final hint = _keyHint;
    final mirrorsTv = PhoneMode.mirrorsTv;
    return FocusedScrollScaffold(
      title: Text(t.ai.settingsTitle),
      slivers: [
        SliverList.list(
          children: [
            if (PhoneMode.isHandheld)
              FocusableSwitchListTile(
                secondary: const AppIcon(Symbols.tv_rounded, fill: 1),
                title: Text(t.ai.mirrorTv),
                subtitle: Text(mirrorsTv ? t.ai.mirrorTvOn : t.ai.mirrorTvOff),
                value: mirrorsTv,
                onChanged: _busy
                    ? null
                    : (v) async {
                        setState(() => _busy = true);
                        await PhoneMode.setMirrorsTv(v);
                        if (!mounted) return;
                        setState(() => _busy = false);
                        await _load();
                      },
              ),
            if (!mirrorsTv) ..._ownAiTiles(hint),
          ],
        ),
      ],
    );
  }

  /// The TMDB key: paste, send from another device, test, remove.
  List<Widget> _tmdbTiles() {
    final hint = _tmdbHint;
    final check = _tmdbCheck;
    return [
      ListTile(
        title: Text(t.ai.tmdbTitle, style: Theme.of(context).textTheme.titleMedium),
        subtitle: Text(t.ai.tmdbExplainer),
      ),
      FocusableListTile(
        key: const ValueKey('tmdb-key'),
        leading: const AppIcon(Symbols.key_rounded, fill: 1),
        title: Text(hint == null ? t.ai.tmdbPasteKey : t.ai.tmdbReplaceKey),
        subtitle: Text(
          !_loaded
              ? '…'
              : hint == null
              ? t.ai.tmdbNoKey
              : [t.ai.tmdbKeySet(hint: hint), if (check != null) _tmdbStatus(check)].join(' · '),
        ),
        onTap: _busy ? null : () => unawaited(_pasteTmdb()),
      ),
      FocusableListTile(
        leading: const AppIcon(Symbols.devices_rounded, fill: 1),
        title: Text(t.ai.tmdbReceiveKey),
        subtitle: Text(t.ai.receiveKeyDescription),
        onTap: _busy ? null : () => unawaited(_receive(kind: KeyReceiverKind.tmdb)),
      ),
      if (hint != null) ...[
        FocusableListTile(
          leading: const AppIcon(Symbols.check_circle_rounded, fill: 1),
          title: Text(t.ai.tmdbTestKey),
          onTap: _busy ? null : () => unawaited(_testTmdb()),
        ),
        FocusableListTile(
          leading: const AppIcon(Symbols.delete_rounded, fill: 1),
          title: Text(t.ai.tmdbRemoveKey),
          onTap: _busy ? null : () => unawaited(_removeTmdb()),
        ),
      ],
    ];
  }

  /// Key, spend and the rest: for a device that runs its own AI.
  List<Widget> _ownAiTiles(String? hint) {
    return [
      ListTile(subtitle: Text(t.ai.keyExplainer)),
      FocusableListTile(
        autofocus: !PhoneMode.isHandheld,
        leading: const AppIcon(Symbols.key_rounded, fill: 1),
        title: Text(hint == null ? t.ai.pasteKey : t.ai.replaceKey),
        subtitle: Text(
          !_loaded
              ? '…'
              : hint == null
              ? t.ai.noKey
              : t.ai.keySet(hint: hint),
        ),
        onTap: _busy ? null : () => unawaited(_paste()),
      ),
      FocusableListTile(
        leading: const AppIcon(Symbols.devices_rounded, fill: 1),
        title: Text(t.ai.receiveKey),
        subtitle: Text(t.ai.receiveKeyDescription),
        onTap: _busy ? null : () => unawaited(_receive()),
      ),
      if (hint != null) ...[
        FocusableListTile(
          leading: const AppIcon(Symbols.check_circle_rounded, fill: 1),
          title: Text(t.ai.testKey),
          onTap: _busy ? null : () => unawaited(_test()),
        ),
        FocusableListTile(
          leading: const AppIcon(Symbols.delete_rounded, fill: 1),
          title: Text(t.ai.removeKey),
          onTap: _busy ? null : () => unawaited(_remove()),
        ),
      ],
      ..._tmdbTiles(),
      if (hint != null)
        FocusableListTile(
          leading: const AppIcon(Symbols.auto_awesome_rounded, fill: 1),
          title: Text(t.ai.tryRequest),
          subtitle: Text(t.ai.tryRequestDescription),
          onTap: () => unawaited(_try()),
        ),
      if (hint != null && kDebugMode)
        FocusableListTile(
          leading: const AppIcon(Symbols.science_rounded, fill: 1),
          title: const Text('Run eval (prompt list × Sonnet)'),
          subtitle: Text(_evalStatus ?? AiEval.promptsFile),
          onTap: _evalStatus != null && !_evalStatus!.startsWith('Done') ? null : () => unawaited(_eval()),
        ),
      if (hint != null)
        FocusableSwitchListTile(
          secondary: const AppIcon(Symbols.autorenew_rounded, fill: 1),
          title: Text(t.ai.autoRefreshTitle),
          subtitle: Text(t.ai.autoRefreshSubtitle),
          value: _autoRefresh,
          onChanged: (v) async {
            setState(() => _autoRefresh = v);
            await AiHomeRefresher.setEnabled(v);
          },
        ),
      if (hint != null && kDebugMode)
        FocusableListTile(
          leading: const AppIcon(Symbols.science_rounded, fill: 1),
          title: const Text('Auto-refresh Home AI rows now (Haiku)'),
          subtitle: Text(_autoRefreshStatus ?? 'Ignores the 12-hour wait'),
          onTap: _autoRefreshStatus == 'Refreshing…'
              ? null
              : () async {
                  setState(() => _autoRefreshStatus = 'Refreshing…');
                  final before = (await AiSpend.month()).autoRefreshDollars;
                  final n = await AiHomeRefresher.check(force: true);
                  final cost = (await AiSpend.month()).autoRefreshDollars - before;
                  if (mounted) {
                    setState(() => _autoRefreshStatus = 'Done: $n rows, \$${cost.toStringAsFixed(4)}');
                  }
                },
        ),
      FutureBuilder(
        future: AiSpend.month(),
        builder: (context, snap) => ListTile(
          title: Text(t.ai.spendTitle, style: Theme.of(context).textTheme.titleMedium),
          subtitle: Text(
            snap.data == null
                ? '…'
                : [
                    t.ai.spendThisMonth(dollars: snap.data!.dollars.toStringAsFixed(2), requests: snap.data!.requests),
                    if (snap.data!.autoRefreshDollars > 0)
                      t.ai.spendAutoRefresh(dollars: snap.data!.autoRefreshDollars.toStringAsFixed(2)),
                  ].join(' · '),
          ),
        ),
      ),
      ListTile(
        title: Text(t.ai.modelsTitle, style: Theme.of(context).textTheme.titleMedium),
        subtitle: Text(t.ai.modelsDescription),
      ),
    ];
  }
}
