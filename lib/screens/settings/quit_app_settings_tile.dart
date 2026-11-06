import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import '../../services/app_exit_service.dart';
import '../../utils/platform_detector.dart';
import '../../widgets/setting_tile.dart';

/// Android TV's real exit. Back at the home root keeps Plezy warm behind the
/// launcher ([AppExitService.exitFromRootBack]), so this is the one place that
/// finishes the task and lets the process go.
class QuitAppSettingsTile extends StatelessWidget {
  const QuitAppSettingsTile({super.key, this.focusNode, this.requestExit = AppExitService.requestExit});

  final FocusNode? focusNode;
  final Future<bool> Function({AppExitApplication? exitApplicationForTesting}) requestExit;

  /// Shown only where Back no longer exits: an Android TV device.
  static bool get isAvailable => Platform.isAndroid && PlatformDetector.isTVDevice();

  @override
  Widget build(BuildContext context) {
    return SettingNavigationTile(
      focusNode: focusNode,
      icon: Symbols.power_settings_new_rounded,
      title: t.settings.quitApp,
      subtitle: t.settings.quitAppDescription,
      onTap: () => unawaited(requestExit()),
    );
  }
}
