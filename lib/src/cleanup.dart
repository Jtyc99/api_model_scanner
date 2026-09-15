import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:path/path.dart' as p;

/// What a cleanup pass changed.
class CleanupResult {
  final List<String> importsStrippedFrom;
  final List<String> deletedFiles;

  const CleanupResult({
    required this.importsStrippedFrom,
    required this.deletedFiles,
  });

  bool get isEmpty => importsStrippedFrom.isEmpty && deletedFiles.isEmpty;
}

/// Tidies up after a removal: drops imports that no longer resolve to anything
/// and deletes files left with no declarations.
///
/// This belongs to `remove` only. `disable` deliberately leaves both alone —
/// the whole point of commenting code out is that everything stays put, ready
/// to be switched back on.
///
/// Unused imports are identified by the analyzer rather than guessed at: only
/// it knows whether a remaining identifier still needs the import.
Future<CleanupResult> cleanupAfterRemoval({
  required String projectRoot,
  required List<String> modifiedFiles,
  required Map<String, String> restoreOnFailure,
  void Function(String message)? log,
}) async {
  final stripped = <String>[];
  final deleted = <String>[];

  // 1. Strip imports the analyzer now reports as unused.
  final unused = await _unusedImports(projectRoot, modifiedFiles);
  for (final entry in unused.entries) {
    final file = File(entry.key);
    if (!file.existsSync()) {
      continue;
    }
    restoreOnFailure.putIfAbsent(entry.key, () => file.readAsStringSync());

    final lines = file.readAsStringSync().split('\n');
    // Delete from the bottom so earlier line numbers stay valid.
    final targets = entry.value.toList()..sort((a, b) => b.compareTo(a));
    for (final line in targets) {
      if (line >= 1 && line <= lines.length) {
        lines.removeAt(line - 1);
      }
    }
    file.writeAsStringSync(lines.join('\n'));
    stripped.add(entry.key);
    log?.call('  - unused import in ${p.relative(entry.key, from: projectRoot)}');
  }

  // 2. Delete files that no longer declare anything.
  for (final path in modifiedFiles) {
    final file = File(path);
    if (!file.existsSync()) {
      continue;
    }
    final content = file.readAsStringSync();
    if (!_declaresNothing(content, path)) {
      continue;
    }
    restoreOnFailure.putIfAbsent(path, () => content);
    file.deleteSync();
    deleted.add(path);
    log?.call('  - empty file ${p.relative(path, from: projectRoot)}');
  }

  return CleanupResult(importsStrippedFrom: stripped, deletedFiles: deleted);
}

/// Whether a source file has no remaining top-level declarations.
bool _declaresNothing(String content, String path) {
  if (content.trim().isEmpty) {
    return true;
  }
  try {
    final unit =
        parseString(content: content, path: path, throwIfDiagnostics: false)
            .unit;
    if (unit.declarations.isNotEmpty) {
      return false;
    }
    // Only directives left (a lone `import`) counts as nothing worth keeping.
    return unit.directives.every((d) => d is ImportDirective);
  } catch (_) {
    return false;
  }
}

/// Maps file path to the 1-based lines the analyzer flags as unused imports.
Future<Map<String, Set<int>>> _unusedImports(
  String projectRoot,
  List<String> files,
) async {
  if (files.isEmpty) {
    return const {};
  }

  final ProcessResult result;
  try {
    result = await Process.run(
      'dart',
      ['analyze', ...files],
      workingDirectory: projectRoot,
      runInShell: true,
    );
  } catch (_) {
    return const {};
  }

  final output = '${result.stdout}${result.stderr}';
  if (output.contains('Usage: dart analyze')) {
    return const {};
  }

  // e.g. `warning - lib/a.dart:1:8 - Unused import: 'b.dart'. … - unused_import`
  final pattern = RegExp(r'-\s+(\S+\.dart):(\d+):\d+\s+-.*-\s+unused_import');
  final byFile = <String, Set<int>>{};

  for (final line in output.split('\n')) {
    final match = pattern.firstMatch(line.trim());
    if (match == null) {
      continue;
    }
    final reported = match.group(1)!;
    // The analyzer prints paths relative to the analysis root, so resolve
    // them against it before comparing. Matching on basename instead would
    // cross line numbers between two edited files that share one — `user.dart`
    // under two directories is ordinary in a model tree — and delete an
    // arbitrary line from the wrong file.
    final absolute = p.normalize(
      p.isAbsolute(reported) ? reported : p.join(projectRoot, reported),
    );
    final resolved = files.firstWhere(
      (f) => p.equals(p.normalize(p.absolute(f)), absolute),
      orElse: () => '',
    );
    if (resolved.isEmpty) {
      continue;
    }
    byFile.putIfAbsent(resolved, () => {}).add(int.parse(match.group(2)!));
  }

  return byFile;
}
