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

  // 2. Delete files that no longer declare anything — unless something still
  //    imports them.
  //
  //    A dangling import is an error in the *importing* file, which need not
  //    be one this run touched, so verifying only the files we edited would
  //    never see it. Rather than widening verification to the whole package,
  //    do not create the breakage: an empty file that someone still imports
  //    is harmless, while deleting it is not.
  final candidates = <String>[];
  for (final path in modifiedFiles) {
    final file = File(path);
    if (!file.existsSync()) {
      continue;
    }
    if (_declaresNothing(file.readAsStringSync(), path)) {
      candidates.add(path);
    }
  }

  if (candidates.isNotEmpty) {
    final importers = _importersOf(projectRoot, candidates);

    for (final path in candidates) {
      // An importer that is itself being deleted holds nothing back.
      final held = (importers[path] ?? const <String>{})
          .where((f) => !candidates.contains(f))
          .toList();

      final rel = p.relative(path, from: projectRoot);

      if (held.isNotEmpty) {
        log?.call('  - kept empty file $rel — still imported by '
            '${held.length} file${held.length == 1 ? '' : 's'}');
        continue;
      }

      final file = File(path);
      restoreOnFailure.putIfAbsent(path, () => file.readAsStringSync());
      file.deleteSync();
      deleted.add(path);
      log?.call('  - empty file $rel');
    }
  }

  return CleanupResult(importsStrippedFrom: stripped, deletedFiles: deleted);
}

/// Maps each of [targets] to the files that still reference it.
///
/// Directives are read from the AST rather than matched textually, and both
/// `package:` and relative URIs are resolved to absolute paths, so an import
/// counts however it is spelled.
Map<String, Set<String>> _importersOf(String projectRoot, List<String> targets) {
  final wanted = {for (final t in targets) p.normalize(p.absolute(t))};
  final result = <String, Set<String>>{};

  final packageName = _packageName(projectRoot);
  final libDir = p.join(projectRoot, 'lib');

  for (final dir in ['lib', 'bin', 'test', 'tool']) {
    final directory = Directory(p.join(projectRoot, dir));
    if (!directory.existsSync()) {
      continue;
    }

    for (final file in directory.listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) {
        continue;
      }
      final from = p.normalize(p.absolute(file.path));
      if (wanted.contains(from)) {
        continue;
      }

      final String content;
      try {
        content = file.readAsStringSync();
      } catch (_) {
        continue;
      }

      final CompilationUnit unit;
      try {
        unit = parseString(
          content: content,
          path: file.path,
          throwIfDiagnostics: false,
        ).unit;
      } catch (_) {
        continue;
      }

      for (final directive in unit.directives) {
        final uri = switch (directive) {
          ImportDirective(:final uri) => uri.stringValue,
          ExportDirective(:final uri) => uri.stringValue,
          PartDirective(:final uri) => uri.stringValue,
          _ => null,
        };
        if (uri == null || uri.startsWith('dart:')) {
          continue;
        }

        final String resolved;
        if (uri.startsWith('package:')) {
          final rest = uri.substring('package:'.length);
          final slash = rest.indexOf('/');
          if (slash == -1 ||
              packageName == null ||
              rest.substring(0, slash) != packageName) {
            continue;
          }
          resolved = p.normalize(p.join(libDir, rest.substring(slash + 1)));
        } else {
          resolved =
              p.normalize(p.join(p.dirname(from), uri));
        }

        if (wanted.contains(resolved)) {
          result.putIfAbsent(resolved, () => <String>{}).add(from);
        }
      }
    }
  }

  return result;
}

/// The `name:` from the project's pubspec, used to resolve `package:` URIs
/// that point back into this same project.
String? _packageName(String projectRoot) {
  final file = File(p.join(projectRoot, 'pubspec.yaml'));
  if (!file.existsSync()) {
    return null;
  }
  try {
    final match = RegExp(r'^name:\s*(\S+)', multiLine: true)
        .firstMatch(file.readAsStringSync());
    return match?.group(1);
  } catch (_) {
    return null;
  }
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
