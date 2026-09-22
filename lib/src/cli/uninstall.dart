import 'dart:io';

import 'package:path/path.dart' as p;

import '../cache/disabled_store.dart';
import 'config.dart';

/// Everything `uninstall` would remove, worked out before anything is.
///
/// Separated from the doing so the user can be shown it and say no, and so
/// the dangerous case — code commented out with no record left to restore it
/// — can be spotted before any of it happens.
class UninstallPlan {
  /// `~/.config/api_model_scanner`, or null when there is none.
  final String? globalConfigDirectory;

  /// `<project>/.dart_tool/api_model_scanner`, or null when there is none.
  final String? projectDirectory;

  /// How many fields are currently commented out in this project.
  final int disabledFieldCount;

  const UninstallPlan({
    this.globalConfigDirectory,
    this.projectDirectory,
    this.disabledFieldCount = 0,
  });

  bool get isEmpty =>
      globalConfigDirectory == null && projectDirectory == null;

  /// Whether going ahead would leave commented-out code unrecoverable.
  ///
  /// `disable` keeps the original source in `disabled_fields.json`; the
  /// comment in the file is not enough to restore it, since `--undo` reads
  /// the record. Deleting it strands that code for good.
  bool get wouldStrandDisabledCode => disabledFieldCount > 0;
}

/// Works out what an uninstall would remove, without removing any of it.
UninstallPlan planUninstall({
  required String projectRoot,
  String? globalConfigPath,
}) {
  final global = p.dirname(globalConfigPath ?? ModelsConfig.globalPath());
  final project = p.join(projectRoot, '.dart_tool', 'api_model_scanner');

  return UninstallPlan(
    globalConfigDirectory:
        Directory(global).existsSync() ? global : null,
    projectDirectory: Directory(project).existsSync() ? project : null,
    disabledFieldCount: DisabledStore(projectRoot).read().length,
  );
}

/// Deletes what [plan] names. Returns the directories actually removed.
///
/// Only this tool's own directories go: `.dart_tool` holds pub's own files
/// and is not ours to delete.
List<String> applyUninstall(UninstallPlan plan) {
  final removed = <String>[];

  for (final directory in [
    plan.projectDirectory,
    plan.globalConfigDirectory,
  ]) {
    if (directory == null) {
      continue;
    }
    final handle = Directory(directory);
    if (!handle.existsSync()) {
      continue;
    }
    handle.deleteSync(recursive: true);
    removed.add(directory);
  }

  return removed;
}

/// Runs `dart pub global deactivate`, so the tool stops being on PATH.
///
/// Last, and tolerant of failure: a path-activated or `dart run` copy was
/// never globally activated, and saying so beats pretending it worked.
({bool ok, String detail}) deactivateSelf() {
  try {
    final result = Process.runSync(
      'dart',
      ['pub', 'global', 'deactivate', 'api_model_scanner'],
      runInShell: Platform.isWindows,
    );
    final output = '${result.stdout}${result.stderr}'.trim();
    return (ok: result.exitCode == 0, detail: output);
  } catch (e) {
    return (ok: false, detail: '$e');
  }
}
