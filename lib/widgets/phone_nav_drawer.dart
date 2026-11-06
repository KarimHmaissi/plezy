import 'dart:io' show Platform;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../focus/focusable_action_bar.dart';
import '../i18n/strings.g.dart';
import '../navigation/main_screen_scope.dart';
import '../navigation/navigation_tabs.dart';
import '../navigation/settings_shortcut.dart';
import '../profiles/active_profile_provider.dart';
import '../profiles/profile_avatar.dart';
import '../providers/companion_remote_provider.dart';
import '../providers/cast_provider.dart';
import '../screens/companion_remote/mobile_remote_screen.dart';
import '../screens/profile/profile_switch_screen.dart';
import '../screens/profile/profile_teardown.dart';
import '../theme/fork_motion.dart';
import '../theme/fork_spacing.dart';
import '../theme/mono_tokens.dart';
import '../utils/dialogs.dart';
import '../utils/platform_detector.dart';
import '../watch_together/watch_together.dart';
import 'app_icon.dart';
import 'cast_sheet.dart';
import 'pressable.dart';

/// Fork: the phone's top-bar actions on every tab, as Plex: Search, Cast, the
/// companion remote and the avatar, which opens [showPhoneNavDrawer] with
/// everything else. Empty off phones (TV and desktop keep their side nav
/// and own toolbars).
///
/// A drawer row: icon, label, action.
typedef PhoneDrawerItem = (IconData icon, String label, VoidCallback onTap);

/// [onRefresh] adds a Refresh row to the drawer for tabs that reload;
/// [extras] are the tab's own actions (e.g. Explore's Manage Home), listed
/// first.
List<FocusableAction> phoneTabActions(
  BuildContext context, {
  Color? color,
  VoidCallback? onRefresh,
  List<PhoneDrawerItem> extras = const [],
}) {
  if (!PlatformDetector.isMobile(context)) return const [];
  final fg = color ?? Theme.of(context).colorScheme.onSurface;
  return [
    FocusableAction(
      icon: Symbols.search_rounded,
      iconColor: fg,
      tooltip: t.common.search,
      onPressed: () => MainTabSwitcher.select?.call(NavigationTabId.search),
    ),
    // Fork: Google Cast (hidden where casting isn't available).
    if (context.read<CastProvider?>()?.available ?? false)
      FocusableAction(
        tooltip: t.googleCast.button,
        onPressed: () => openCastPicker(context),
        child: CastButton(color: fg),
      ),
    FocusableAction(
      tooltip: t.companionRemote.title,
      onPressed: () => _openRemote(context),
      child: _RemoteIcon(color: fg, onPressed: () => _openRemote(context)),
    ),
    FocusableAction(
      tooltip: t.profiles.sectionTitle,
      onPressed: () => showPhoneNavDrawer(context, onRefresh: onRefresh, extras: extras),
      child: _AvatarButton(
        onPressed: () => showPhoneNavDrawer(context, onRefresh: onRefresh, extras: extras),
      ),
    ),
  ];
}

void _openRemote(BuildContext context) {
  ForkMotion.selection();
  Navigator.push(context, MaterialPageRoute(builder: (_) => const MobileRemoteScreen()));
}

class _RemoteIcon extends StatelessWidget {
  const _RemoteIcon({required this.color, required this.onPressed});
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final connected = context.select<CompanionRemoteProvider, bool>((p) => p.isConnected);
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: t.companionRemote.title,
      onPressed: onPressed,
      icon: Badge(
        isLabelVisible: connected,
        smallSize: 8,
        backgroundColor: scheme.primary,
        child: AppIcon(
          Symbols.phone_android_rounded,
          fill: connected ? 1 : 0,
          color: connected ? scheme.primary : color,
        ),
      ),
    );
  }
}

class _AvatarButton extends StatelessWidget {
  const _AvatarButton({required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final profiles = context.watch<ActiveProfileProvider>();
    final active = profiles.active;
    return IconButton(
      tooltip: t.profiles.sectionTitle,
      onPressed: onPressed,
      icon: active != null
          ? ProfileAvatar(profile: active, size: 30, avatarUrl: profiles.avatarUrlFor(active.id))
          : const AppIcon(Symbols.account_circle_rounded, fill: 1, size: 30),
    );
  }
}

/// Opens the phone's side drawer from the right: the profile at the top,
/// then Libraries, History, Downloads, Watch Together, Refresh (when the tab
/// supports it), Switch profile, Settings and Log out. Swipe right, tap the
/// scrim or press Back to close.
Future<void> showPhoneNavDrawer(
  BuildContext context, {
  VoidCallback? onRefresh,
  List<PhoneDrawerItem> extras = const [],
}) {
  ForkMotion.selection();
  final scope = MainScreenFocusScope.of(context, listen: false);
  return Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.black54,
      transitionDuration: ForkMotion.sheetIn,
      reverseTransitionDuration: ForkMotion.sheetOut,
      pageBuilder: (routeContext, _, _) => _PhoneNavDrawer(
        onRefresh: onRefresh,
        extras: extras,
        openSettings: scope?.openSettings,
        hostContext: context,
      ),
      transitionsBuilder: (context, animation, _, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: ForkMotion.enterCurve,
          reverseCurve: ForkMotion.exitCurve,
        );
        return SlideTransition(
          position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(curved),
          child: child,
        );
      },
    ),
  );
}

class _PhoneNavDrawer extends StatefulWidget {
  const _PhoneNavDrawer({
    required this.onRefresh,
    required this.extras,
    required this.openSettings,
    required this.hostContext,
  });

  final VoidCallback? onRefresh;
  final List<PhoneDrawerItem> extras;
  final VoidCallback? openSettings;

  /// The tab that opened the drawer, for actions that run after it closes.
  final BuildContext hostContext;

  @override
  State<_PhoneNavDrawer> createState() => _PhoneNavDrawerState();
}

class _PhoneNavDrawerState extends State<_PhoneNavDrawer> {
  double _drag = 0;

  /// Close the drawer, then run [action] against the tab behind it.
  void _then(VoidCallback action) {
    ForkMotion.selection();
    Navigator.of(context).pop();
    action();
  }

  @override
  Widget build(BuildContext context) {
    final tk = tokens(context);
    final theme = Theme.of(context);
    final spacing = ForkSpacing.of(context);
    final width = (MediaQuery.sizeOf(context).width * 0.82).clamp(260.0, 340.0);
    final profiles = context.watch<ActiveProfileProvider>();
    final active = profiles.active;
    final host = widget.hostContext;

    final rows = <PhoneDrawerItem>[
      ...widget.extras,
      // Fork: the Reel takes Explore's bottom-bar slot on Android.
      if (Platform.isAndroid)
        (Symbols.explore_rounded, t.navigation.explore, () => MainTabSwitcher.select?.call(NavigationTabId.explore)),
      (
        Symbols.video_library_rounded,
        t.navigation.libraries,
        () => MainTabSwitcher.select?.call(NavigationTabId.libraries),
      ),
      (Symbols.history_rounded, t.navigation.history, () => MainTabSwitcher.select?.call(NavigationTabId.history)),
      (Symbols.download_rounded, t.navigation.downloads, () => MainTabSwitcher.select?.call(NavigationTabId.downloads)),
      (
        Symbols.group_rounded,
        t.watchTogether.title,
        () => Navigator.push(host, MaterialPageRoute(builder: (_) => const WatchTogetherScreen())),
      ),
      if (widget.onRefresh case final refresh?) (Symbols.refresh_rounded, t.common.refresh, refresh),
      (
        Symbols.switch_account_rounded,
        t.profiles.sectionTitle,
        () => Navigator.of(
          host,
          rootNavigator: true,
        ).push(MaterialPageRoute(builder: (_) => const ProfileSwitchScreen())),
      ),
      (
        Symbols.settings_rounded,
        t.common.settings,
        () => widget.openSettings != null ? widget.openSettings!() : Navigator.push(host, buildSettingsRoute()),
      ),
      (Symbols.logout_rounded, t.common.logout, () => unawaited(_logout(host))),
    ];

    return Align(
      alignment: Alignment.centerRight,
      child: GestureDetector(
        // Swipe right to close, following the finger.
        onHorizontalDragUpdate: (d) => setState(() => _drag = (_drag + d.delta.dx).clamp(0, width)),
        onHorizontalDragEnd: (d) {
          if (_drag > width * 0.3 || d.primaryVelocity! > 600) {
            Navigator.of(context).pop();
          } else {
            setState(() => _drag = 0);
          }
        },
        child: Transform.translate(
          offset: Offset(_drag, 0),
          child: Material(
            color: tk.surface,
            child: SizedBox(
              width: width,
              height: double.infinity,
              child: SafeArea(
                left: false,
                child: ListView(
                  padding: EdgeInsets.fromLTRB(0, 32, 0, 24),
                  children: [
                    Center(
                      child: active != null
                          ? ProfileAvatar(profile: active, size: 88, avatarUrl: profiles.avatarUrlFor(active.id))
                          : AppIcon(Symbols.account_circle_rounded, fill: 1, size: 88, color: tk.textMuted),
                    ),
                    if (active != null) ...[
                      const SizedBox(height: 14),
                      Text(
                        active.displayName,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ],
                    SizedBox(height: spacing.rowGap - 8),
                    for (final (icon, label, action) in rows)
                      Pressable(
                        longPress: false,
                        child: InkWell(
                          onTap: () => _then(action),
                          child: Padding(
                            padding: EdgeInsets.symmetric(horizontal: spacing.edgeInset, vertical: 14),
                            child: Row(
                              children: [
                                AppIcon(icon, size: 24, color: tk.text),
                                const SizedBox(width: 18),
                                Expanded(child: Text(label, style: theme.textTheme.bodyLarge)),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static Future<void> _logout(BuildContext context) async {
    final confirm = await showConfirmDialog(
      context,
      title: t.common.logout,
      message: t.messages.logoutConfirm,
      confirmText: t.common.logout,
      isDestructive: true,
    );
    if (confirm && context.mounted) await logoutAllProfiles(context);
  }
}
