import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import '../../services/customisation/customisation_store.dart';
import '../../services/reel/reel_store.dart';
import '../../services/reel_app.dart';
import '../../utils/app_logger.dart';
import '../../utils/dialogs.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focusable_list_tile.dart';

/// For You in the Reel: their own words to the daily build (a synced note,
/// so it can be typed on the phone and read by the TV's build) and
/// "Rebuild today's For You". Shown on the Reel's settings page (V2-46),
/// under a For You group of its own.
class ReelForYouTiles extends StatefulWidget {
  const ReelForYouTiles({super.key, this.store, this.rebuild, this.showTitle = true});

  /// Whether the explainer carries its own title; false under a group
  /// header that already names it.
  final bool showTitle;

  /// Tests: the store the note is kept in (the app's by default).
  final ReelStore? store;

  /// Tests: the rebuild ([ReelApp.rebuildForYouToday] by default); returns
  /// whether this device does it.
  final Future<bool> Function()? rebuild;

  @override
  State<ReelForYouTiles> createState() => _ReelForYouTilesState();
}

class _ReelForYouTilesState extends State<ReelForYouTiles> {
  ReelStore get _store => widget.store ?? ReelStore.instance;

  String? _note;
  bool _loaded = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // The note is synced: an edit on the other device shows here.
    Customisation.changed.addListener(_reload);
    unawaited(_load());
  }

  @override
  void dispose() {
    Customisation.changed.removeListener(_reload);
    super.dispose();
  }

  void _reload() => unawaited(_load());

  Future<void> _load() async {
    String? note;
    try {
      note = await _store.forYouNote();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _note = note;
      _loaded = true;
    });
  }

  Future<void> _edit() async {
    final text = await showTextInputDialog(
      context,
      title: t.reelForYou.note,
      labelText: t.reelForYou.noteLabel,
      hintText: t.reelForYou.noteHint,
      initialValue: _note,
      confirmText: t.common.save,
      allowEmpty: true,
      multiline: true,
    );
    if (text == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await _store.setForYouNote(text);
      final note = await _store.forYouNote();
      if (!mounted) return;
      setState(() => _note = note);
      showAppSnackBar(context, note == null ? t.reelForYou.noteRemoved : t.reelForYou.noteSaved);
    } catch (e) {
      // A phone mirroring a TV it isn't connected to can't write.
      appLogger.w('Reel: For You note not saved', error: e);
      if (mounted) showErrorSnackBar(context, t.reelForYou.noteFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _rebuild() async {
    setState(() => _busy = true);
    try {
      final here = await (widget.rebuild ?? ReelApp.rebuildForYouToday)();
      if (!mounted) return;
      showAppSnackBar(context, here ? t.reelForYou.rebuildHere : t.reelForYou.rebuildOnTv);
    } catch (e) {
      appLogger.w("Reel: today's For You not cleared", error: e);
      if (mounted) showErrorSnackBar(context, t.reelForYou.rebuildFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final note = _note;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.showTitle)
          ListTile(
            title: Text(t.reelForYou.title, style: Theme.of(context).textTheme.titleMedium),
            subtitle: Text(t.reelForYou.explainer),
          )
        else
          ListTile(subtitle: Text(t.reelForYou.explainer)),
        FocusableListTile(
          leading: const AppIcon(Symbols.edit_note_rounded, fill: 1),
          title: Text(t.reelForYou.note),
          subtitle: Text(!_loaded ? '…' : note ?? t.reelForYou.noteEmpty, maxLines: 3, overflow: TextOverflow.ellipsis),
          onTap: _busy ? null : () => unawaited(_edit()),
        ),
        FocusableListTile(
          leading: const AppIcon(Symbols.refresh_rounded, fill: 1),
          title: Text(t.reelForYou.rebuild),
          subtitle: Text(t.reelForYou.rebuildSubtitle),
          onTap: _busy ? null : () => unawaited(_rebuild()),
        ),
      ],
    );
  }
}
