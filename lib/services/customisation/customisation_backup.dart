import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../utils/platform_detector.dart';
import '../catalog/home_pins.dart';
import '../file_picker_service.dart';
import 'customisation_store.dart';

/// Export and import of the fork's customisation data (Home rows, Comfort
/// pauses, Shortlist, settings) as one JSON file, for moving between
/// devices. Backups are saved to a fixed Plezy folder and import lists the
/// files found there, so both work with a remote; where a system file dialog
/// exists (not Android TV), import can also pick a file from anywhere.
abstract final class CustomisationBackup {
  static const String _prefix = 'plezy-backup-';

  /// Whether this device can pick a file with a system dialog.
  static bool get usesFilePicker => !Platform.isAndroid || !PlatformDetector.isTV();

  /// The folder backups are saved to and listed from without a picker:
  /// Android → the app's external files folder (`Android/data/{app}/files/Plezy
  /// backups`, reachable over USB or adb); elsewhere → Documents/Plezy.
  static Future<Directory> backupFolder() async {
    final base = Platform.isAndroid
        ? (await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory())
        : await getApplicationDocumentsDirectory();
    final folder = Directory(p.join(base.path, Platform.isAndroid ? 'Plezy backups' : 'Plezy'));
    if (!await folder.exists()) await folder.create(recursive: true);
    return folder;
  }

  static String fileNameFor(DateTime now) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '$_prefix${now.year}-${two(now.month)}-${two(now.day)}-${two(now.hour)}${two(now.minute)}.json';
  }

  /// Write a backup to [backupFolder] (no dialog, so it works with a remote)
  /// and return where it was saved.
  static Future<String> export() async {
    final store = await Customisation.store;
    final version = await PackageInfo.fromPlatform().then((i) => i.version).catchError((Object _) => 'unknown');
    final text = CustomisationExport.encode(await store.exportAll(), appVersion: version);
    final bytes = Uint8List.fromList(utf8.encode(text));
    final name = fileNameFor(DateTime.now());
    final file = File(p.join((await backupFolder()).path, name));
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  /// Backups in [backupFolder], newest first.
  static Future<List<File>> listBackups() async {
    final folder = await backupFolder();
    final files = [
      for (final entity in folder.listSync())
        if (entity is File && entity.path.toLowerCase().endsWith('.json')) entity,
    ];
    files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    return files;
  }

  /// A backup chosen in the system dialog, as text, or null if cancelled.
  static Future<String?> pickBackupText() async {
    final result = await FilePickerService.instance.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
      withData: true,
    );
    final file = result?.files.firstOrNull;
    if (file == null) return null;
    final bytes = file.bytes ?? (file.path == null ? null : await File(file.path!).readAsBytes());
    return bytes == null ? null : utf8.decode(bytes, allowMalformed: true);
  }

  /// Replace this device's customisation data with [data] (validated by
  /// [CustomisationExport.decode]) and reload what's on screen.
  static Future<void> apply(Map<String, Object?> data) async {
    await (await Customisation.store).importAll(data);
    await HomePinsController.instance.ensureLoaded(refresh: true);
  }
}
