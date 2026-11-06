import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import '../../services/customisation/customisation_store.dart';
import '../../services/reel/reel_deck_prefs.dart';
import '../../services/reel/reel_store.dart';
import '../../services/reel_app.dart';
import '../../theme/fork_motion.dart';
import '../../utils/app_logger.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_menu.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/fork_motion_widgets.dart';
import '../../widgets/settings_page.dart';
import '../../widgets/settings_section.dart';

/// A deck as the Decks screen lists it.
typedef ReelDeckInfo = ({String id, String name});

/// The icon a deck shows in the pickers and on the Decks screen.
IconData reelDeckIcon(String id) => switch (id) {
  ReelDeckPrefs.forYouId => Symbols.auto_awesome_rounded,
  'anime-openings' => Symbols.music_note_rounded,
  'most-watched' => Symbols.trending_up_rounded,
  _ => Symbols.chat_bubble_rounded,
};

enum _DeckAction { top, up, down, hide, show }

/// Fork: the Reel's decks (V2-52), modelled on the Home builder: where the
/// Reel starts, then every deck in the user's order (move, pin to the top,
/// hide). Synced between the TV and the phone. Opened from the Reel's
/// settings page and from "Arrange decks" in both deck pickers.
class ReelDecksScreen extends StatefulWidget {
  const ReelDecksScreen({super.key, this.decks, this.store});

  /// The decks to arrange, in the app's own order. Defaults to the Reel's
  /// own list ([ReelApp.deckList]).
  final Future<List<ReelDeckInfo>> Function(BuildContext context)? decks;

  final ReelStore? store;

  @override
  State<ReelDecksScreen> createState() => _ReelDecksScreenState();
}

class _ReelDecksScreenState extends State<ReelDecksScreen> {
  List<ReelDeckInfo>? _decks;
  ReelDeckPrefs _prefs = ReelDeckPrefs.none;
  final Map<String, FocusNode> _nodes = {};
  late final Listenable _changes = Listenable.merge([ReelStore.deckPrefsChanged, Customisation.changed]);

  ReelStore get _store => widget.store ?? ReelStore.instance;

  @override
  void initState() {
    super.initState();
    _changes.addListener(_readPrefs);
    unawaited(_load());
  }

  @override
  void dispose() {
    _changes.removeListener(_readPrefs);
    for (final n in _nodes.values) {
      n.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    List<ReelDeckInfo> decks;
    try {
      decks = await (widget.decks ?? ReelApp.deckList)(context);
    } catch (e) {
      appLogger.w('Reel decks: list unavailable', error: e);
      decks = const [];
    }
    await _readPrefs();
    if (mounted) setState(() => _decks = decks);
  }

  Future<void> _readPrefs() async {
    try {
      final prefs = await _store.deckPrefs();
      if (mounted && prefs != _prefs) setState(() => _prefs = prefs);
    } catch (e) {
      appLogger.d('Reel decks: prefs unavailable', error: e);
    }
  }

  Future<void> _write(ReelDeckPrefs next, {String? focus}) async {
    final was = _prefs;
    if (next == was) return;
    ForkMotion.selection();
    setState(() => _prefs = next);
    if (focus != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _nodes[focus]?.requestFocus();
      });
    }
    try {
      await _store.writeDeckPrefs(next, was: was);
    } catch (e) {
      appLogger.w('Reel decks: save failed', error: e);
      if (!mounted) return;
      setState(() => _prefs = was);
      showErrorSnackBar(context, t.reel.decks.saveFailed);
    }
  }

  Future<void> _deckMenu(BuildContext tileContext, ReelDeckInfo deck, List<ReelDeckInfo> arranged) async {
    final s = t.reel.decks;
    final ids = [for (final d in arranged) d.id];
    final i = ids.indexOf(deck.id);
    final hidden = _prefs.hidden.contains(deck.id);
    final box = tileContext.findRenderObject() as RenderBox?;
    final action = await showAdaptiveAppMenu<_DeckAction>(
      context,
      title: deck.name,
      anchorRect: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
      focusFirstItem: true,
      entries: [
        if (i > 0) ...[
          AppMenuItem(value: _DeckAction.up, label: s.moveUp, icon: Symbols.arrow_upward_rounded),
          if (i > 1) AppMenuItem(value: _DeckAction.top, label: s.moveToTop, icon: Symbols.vertical_align_top_rounded),
        ],
        if (i < ids.length - 1)
          AppMenuItem(value: _DeckAction.down, label: s.moveDown, icon: Symbols.arrow_downward_rounded),
        if (hidden)
          AppMenuItem(value: _DeckAction.show, label: s.show, icon: Symbols.visibility_rounded)
        else if (_prefs.canHide(ids, deck.id))
          AppMenuItem(value: _DeckAction.hide, label: s.hide, icon: Symbols.visibility_off_rounded),
      ],
    );
    if (action == null || !mounted) return;
    ReelDeckPrefs move(int by) => _prefs.moved(known: ids, id: deck.id, by: by);
    await _write(switch (action) {
      _DeckAction.up => move(-1),
      _DeckAction.top => move(-ids.length),
      _DeckAction.down => move(1),
      _DeckAction.hide => _prefs.withHidden(deck.id, hide: true),
      _DeckAction.show => _prefs.withHidden(deck.id, hide: false),
    }, focus: deck.id);
  }

  @override
  Widget build(BuildContext context) {
    final s = t.reel.decks;
    final decks = _decks;
    final arranged = decks == null ? const <ReelDeckInfo>[] : _prefs.arrange(decks, (d) => d.id);
    return SettingsPage(
      title: Text(s.title),
      children: [
        ForkEntrance(
          child: SettingsGroup(
            children: [
              SegmentedSetting<ReelStartDeck>(
                icon: Symbols.play_circle_rounded,
                title: s.startOn,
                segments: [
                  ButtonSegment(value: ReelStartDeck.forYou, label: Text(s.startForYou)),
                  ButtonSegment(value: ReelStartDeck.last, label: Text(s.startLast)),
                ],
                selected: _prefs.start,
                onChanged: (v) => unawaited(_write(_prefs.withStart(v))),
              ),
            ],
          ),
        ),
        ForkEntrance(
          index: 1,
          child: SettingsGroup(
            title: s.yourDecks,
            children: [
              if (decks == null)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (arranged.isEmpty)
                ListTile(subtitle: Text(s.none))
              else
                for (final (i, deck) in arranged.indexed) _deckTile(deck, i, arranged),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: Text(
            s.syncedNote,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  Widget _deckTile(ReelDeckInfo deck, int i, List<ReelDeckInfo> arranged) {
    final hidden = _prefs.hidden.contains(deck.id);
    final scheme = Theme.of(context).colorScheme;
    return Builder(
      builder: (tileContext) => FocusableListTile(
        focusNode: _nodes.putIfAbsent(deck.id, () => FocusNode(debugLabel: 'reelDeck')),
        leading: AppIcon(reelDeckIcon(deck.id), fill: 1, color: hidden ? scheme.onSurfaceVariant : null),
        title: Text(deck.name, style: hidden ? TextStyle(color: scheme.onSurfaceVariant) : null),
        subtitle: hidden ? Text(t.reel.decks.hiddenDescription) : null,
        trailing: const AppIcon(Symbols.more_vert_rounded),
        onTap: () => unawaited(_deckMenu(tileContext, deck, arranged)),
      ),
    );
  }
}
