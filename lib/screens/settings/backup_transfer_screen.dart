import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:path/path.dart' as p;

import '../../i18n/strings.g.dart';
import '../../services/customisation/customisation_backup.dart';
import '../../services/customisation/customisation_store.dart';
import '../../utils/app_logger.dart';
import '../../utils/dialogs.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/focused_scroll_scaffold.dart';

/// Settings ▸ Backup & transfer: export this device's Home rows, Comfort
/// pauses and other customisations to a file, or replace them from one.
class BackupTransferScreen extends StatefulWidget {
  const BackupTransferScreen({super.key});

  @override
  State<BackupTransferScreen> createState() => _BackupTransferScreenState();
}

class _BackupTransferScreenState extends State<BackupTransferScreen> {
  List<File> _backups = const [];
  String? _folder;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadBackups());
  }

  Future<void> _loadBackups() async {
    try {
      final folder = await CustomisationBackup.backupFolder();
      final backups = await CustomisationBackup.listBackups();
      if (!mounted) return;
      setState(() {
        _folder = folder.path;
        _backups = backups;
      });
    } catch (e) {
      appLogger.w('Backup: listing backups failed', error: e);
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export() => _run(() async {
    try {
      final path = await CustomisationBackup.export();
      if (!mounted) return;
      await _loadBackups();
      if (!mounted) return;
      await showConfirmDialog(
        context,
        title: t.backupTransfer.exported,
        message: t.backupTransfer.exportedTo(path: path),
        confirmText: t.common.ok,
      );
    } catch (e) {
      appLogger.w('Backup: export failed', error: e);
      if (mounted) showErrorSnackBar(context, t.backupTransfer.exportFailed);
    }
  });

  Future<void> _importText(String? text, {String? name}) async {
    if (text == null) return;
    final Map<String, Object?> data;
    try {
      data = CustomisationExport.decode(text);
    } on FormatException catch (e) {
      if (!mounted) return;
      showErrorSnackBar(context, switch (e.message) {
        'newerVersion' => t.backupTransfer.newerVersion,
        _ => t.backupTransfer.notABackup,
      });
      return;
    }
    final counts = CustomisationExport.summary(data);
    final exportedAt = DateTime.tryParse(data['exportedAt'] as String? ?? '')?.toLocal();
    if (!mounted) return;
    final confirmed = await showConfirmDialog(
      context,
      title: t.backupTransfer.replaceTitle,
      message: t.backupTransfer.replaceMessage(
        homeRows: counts.homeRows,
        paused: counts.comfortPaused,
        when: exportedAt == null ? (name ?? '') : MaterialLocalizations.of(context).formatMediumDate(exportedAt),
      ),
      confirmText: t.backupTransfer.replace,
      isDestructive: true,
    );
    if (!confirmed) return;
    try {
      await CustomisationBackup.apply(data);
      if (mounted) showSuccessSnackBar(context, t.backupTransfer.imported);
    } catch (e) {
      appLogger.w('Backup: import failed', error: e);
      if (mounted) showErrorSnackBar(context, t.backupTransfer.importFailed);
    }
  }

  Future<void> _importPicked() => _run(() async {
    try {
      await _importText(await CustomisationBackup.pickBackupText());
    } catch (e) {
      appLogger.w('Backup: picking a file failed', error: e);
      if (mounted) showErrorSnackBar(context, t.backupTransfer.importFailed);
    }
  });

  Future<void> _importFile(File file) => _run(() async {
    try {
      await _importText(await file.readAsString(), name: p.basename(file.path));
    } catch (e) {
      appLogger.w('Backup: reading ${file.path} failed', error: e);
      if (mounted) showErrorSnackBar(context, t.backupTransfer.importFailed);
    }
  });

  @override
  Widget build(BuildContext context) {
    final folder = _folder;
    return FocusedScrollScaffold(
      title: Text(t.backupTransfer.title),
      slivers: [
        SliverList.list(
          children: [
            ListTile(subtitle: Text(t.backupTransfer.description)),
            FocusableListTile(
              autofocus: true,
              leading: const AppIcon(Symbols.upload_rounded, fill: 1),
              title: Text(t.backupTransfer.export),
              subtitle: Text(t.backupTransfer.exportDescriptionFolder(folder: folder ?? '…')),
              onTap: _busy ? null : () => unawaited(_export()),
            ),
            if (CustomisationBackup.usesFilePicker)
              FocusableListTile(
                leading: const AppIcon(Symbols.download_rounded, fill: 1),
                title: Text(t.backupTransfer.importFromFile),
                subtitle: Text(t.backupTransfer.importDescription),
                onTap: _busy ? null : () => unawaited(_importPicked()),
              ),
            ListTile(
              title: Text(t.backupTransfer.backupsHere, style: Theme.of(context).textTheme.titleMedium),
              subtitle: folder == null ? null : Text(folder),
            ),
            if (_backups.isEmpty) ListTile(subtitle: Text(t.backupTransfer.noBackups)),
            for (final file in _backups)
              FocusableListTile(
                leading: const AppIcon(Symbols.description_rounded, fill: 1),
                title: Text(p.basename(file.path)),
                subtitle: Text(t.backupTransfer.restoreThis),
                onTap: _busy ? null : () => unawaited(_importFile(file)),
              ),
          ],
        ),
      ],
    );
  }
}
