import 'dart:io';

import 'package:path/path.dart' as p;

import 'model_field_fixer.dart';

/// A model field that was determined to be unused and is a candidate for
/// removal. Kept independent of the scanner's own `ModelField` type so this
/// runner can be shared by any entry point.
class UnusedField {
  final String filePath;
  final String className;
  final String fieldName;

  const UnusedField({
    required this.filePath,
    required this.className,
    required this.fieldName,
  });
}

/// Outcome of an [applyFixes] run.
class FixRunSummary {
  final List<String> modifiedFiles;
  final bool dryRun;

  const FixRunSummary({required this.modifiedFiles, required this.dryRun});
}

/// Applies AST-aware removals for every field in [unused], grouped by file and
/// class so each file is parsed and edited once.
///
/// When [dryRun] is true, nothing is written and the exact edits are printed.
/// When [apply] is true, files are written and (if [runFormat]) `dart format`
/// is run on the modified files.
///
/// This is the single place both the scanner and the fixer entry points route
/// through, so the actual removal behaviour can never drift between them.
Future<FixRunSummary> applyFixes({
  required String projectRoot,
  required List<UnusedField> unused,
  required bool apply,
  required bool dryRun,
  required bool runFormat,
}) async {
  // Group by file, then by class.
  final byFile = <String, Map<String, Set<String>>>{};
  for (final field in unused) {
    byFile
        .putIfAbsent(field.filePath, () => {})
        .putIfAbsent(field.className, () => {})
        .add(field.fieldName);
  }

  final modifiedFiles = <String>[];

  for (final entry in byFile.entries) {
    final filePath = entry.key;
    final byClass = entry.value;
    final rel = p.relative(filePath, from: projectRoot);

    final file = File(filePath);
    var working = await file.readAsString();
    var fileChanged = false;

    for (final classEntry in byClass.entries) {
      final result = ModelFieldFixer.removeFields(
        content: working,
        path: filePath,
        className: classEntry.key,
        fieldNames: classEntry.value,
      );

      if (result.error != null) {
        stderr.writeln('  ! ${classEntry.key}: ${result.error}');
        continue;
      }

      print('$rel  ${classEntry.key}');
      for (final fieldName in classEntry.value) {
        final removed = result.removedFields.contains(fieldName);
        print('    ${removed ? '-' : '?'} $fieldName'
            '${removed ? '' : '  (declaration not found — skipped)'}');
      }
      if (dryRun) {
        for (final edit in result.edits) {
          print('        · ${edit.label}');
        }
      }

      if (result.changed) {
        working = result.newContent;
        fileChanged = true;
      }
    }

    if (fileChanged && apply) {
      await file.writeAsString(working);
      modifiedFiles.add(filePath);
    }
    print('');
  }

  if (dryRun) {
    print('Dry run complete. No files were modified.');
    return FixRunSummary(modifiedFiles: const [], dryRun: true);
  }

  if (modifiedFiles.isEmpty) {
    print('No files were modified.');
    return FixRunSummary(modifiedFiles: const [], dryRun: false);
  }

  print('Modified ${modifiedFiles.length} file(s).');

  if (runFormat) {
    print('Running dart format...');
    final result = await Process.run(
      'dart',
      ['format', ...modifiedFiles],
      workingDirectory: projectRoot,
      runInShell: true,
    );
    if (result.exitCode != 0) {
      stderr.writeln('dart format failed:\n${result.stderr}');
    } else {
      stdout.write(result.stdout);
    }
  }

  print('\nDone. Review the changes with `git diff` before committing.');
  return FixRunSummary(modifiedFiles: modifiedFiles, dryRun: false);
}

/// Returns true when the git working tree has uncommitted changes, false when
/// clean, and null when git status could not be determined (e.g. not a repo).
Future<bool?> gitWorkingTreeDirty(String projectRoot) async {
  try {
    final result = await Process.run(
      'git',
      ['status', '--porcelain'],
      workingDirectory: projectRoot,
      runInShell: true,
    );
    if (result.exitCode != 0) {
      return null;
    }
    return (result.stdout as String).trim().isNotEmpty;
  } catch (_) {
    return null;
  }
}
