import 'dart:io';

import 'package:path/path.dart' as p;

import 'cache/disabled_store.dart';
import 'cleanup.dart';
import 'cache/selection.dart';
import 'cache/unused_cache.dart';
import 'model_field_fixer.dart';
import 'scanning/model_discovery.dart';

/// Ranks each commented range among the identically-worded ranges in the same
/// file, keyed by its start offset.
///
/// This is what lets `--undo` tell two byte-identical ranges apart — `num? id,`
/// as a constructor parameter and again in `copyWith` — instead of putting the
/// first one back twice.
/// [before] is the file as it stood prior to these ranges being written. Any
/// `/*text*/` already in it is a range recorded earlier — by the main pass of
/// this run, or by an earlier `disable` — so counting those first keeps the
/// numbering distinct instead of restarting at 0 and colliding with them.
Map<int, int> _rankByText(List<CommentedRange> ranges, String before) {
  final byText = <String, List<CommentedRange>>{};
  for (final range in ranges) {
    byText.putIfAbsent(range.text, () => []).add(range);
  }

  final rank = <int, int>{};
  for (final entry in byText.entries) {
    var next = _countOccurrences(before, '/*${entry.key}*/');
    final list = entry.value..sort((a, b) => a.start.compareTo(b.start));
    for (final range in list) {
      rank[range.start] = next++;
    }
  }
  return rank;
}

int _countOccurrences(String haystack, String needle) {
  var count = 0;
  var from = 0;
  while (true) {
    final index = haystack.indexOf(needle, from);
    if (index == -1) {
      return count;
    }
    count++;
    from = index + needle.length;
  }
}

/// Pseudo field name recording that a whole class was taken, so the disabled
/// record can restore it as one unit.
const String _wholeClass = '(whole class)';

/// Outcome of an [applySelection] run.
class ApplySummary {
  final List<String> modifiedFiles;
  final int fieldsTouched;
  final int partsTouched;
  final List<String> skipped;

  /// Files that were written and then restored because the edit broke them.
  final List<String> revertedFiles;

  /// Fields actually acted on, keyed `file|class|field`.
  final Set<String> handledKeys;

  /// For comment mode, the snippets wrapped for each field.
  final List<DisabledField> disabled;

  const ApplySummary({
    required this.modifiedFiles,
    required this.fieldsTouched,
    required this.partsTouched,
    required this.skipped,
    this.revertedFiles = const [],
    this.handledKeys = const {},
    this.disabled = const [],
  });
}

/// Applies [mode] to whatever [selection] covers among [fields].
///
/// Every field's plan is computed against the file's original content, so all
/// offsets share one frame of reference and the whole file can be rewritten in
/// a single pass.
Future<ApplySummary> applySelection({
  required String projectRoot,
  required List<CachedField> fields,
  required Selection selection,
  required EditMode mode,
  required bool runFormat,
  Map<String, Set<String>> deadClasses = const {},

  /// Every `extends` edge in the models tree, so subclasses that forward a
  /// removed field from *another* file can be fixed alongside it. Empty means
  /// same-file subclasses only.
  List<SubclassLink> subclassLinks = const [],
  bool verify = true,
  void Function(String message)? log,
}) async {
  void say(String message) => (log ?? stdout.writeln)(message);

  final verb = mode == EditMode.delete ? 'Removed' : 'Disabled';

  final byFile = <String, Map<String, List<CachedField>>>{};
  for (final field in fields) {
    byFile
        .putIfAbsent(field.filePath, () => {})
        .putIfAbsent(field.className, () => [])
        .add(field);
  }

  final modifiedFiles = <String>[];
  final skipped = <String>[];
  final originals = <String, String>{};
  final handledKeys = <String>{};
  final disabled = <DisabledField>[];
  var fieldsTouched = 0;
  var partsTouched = 0;

  // What each class actually gave up, and where it lives — the inputs the
  // cross-file subclass pass needs once every selected file is rewritten.
  final removedByClass = <String, Set<String>>{};
  final classFile = <String, String>{};

  for (final fileEntry in byFile.entries) {
    final filePath = fileEntry.key;
    final rel = p.relative(filePath, from: projectRoot);
    final file = File(filePath);

    if (!file.existsSync()) {
      say('  ! $rel no longer exists — skipped');
      continue;
    }

    final original = await file.readAsString();
    final chosen = <Edit>[];
    final fieldRanges = <String, List<Edit>>{};
    var printedFile = false;

    // A dead class is removed whole: its declaration subsumes every field
    // edit inside it, and leaving an empty husk behind helps nobody.
    //
    // The verdict was reached assuming every unused field would go, so it has
    // to be re-checked against what was actually ticked. A class whose last
    // reference lives in a field the user left alone is not dead at all, and
    // taking it would leave that field naming a type that no longer exists —
    // in a file this run may not otherwise touch, so verification could miss
    // it entirely.
    bool stillDead(String className) {
      final conditions = deadClasses[className];
      if (conditions == null) {
        return false;
      }
      return conditions.every((key) {
        final dot = key.indexOf('.');
        if (dot <= 0) {
          return false;
        }
        return selection.selectsWholeField(
          key.substring(0, dot),
          key.substring(dot + 1),
        );
      });
    }

    final deadHere = <String>{
      for (final className in fileEntry.value.keys)
        if (stillDead(className) &&
            fileEntry.value[className]!.every((f) =>
                selection.selectsWholeField(className, f.fieldName)))
          className,
    };

    // Planned one class at a time so each commented range can be attributed
    // back to its class — otherwise `--undo` would restore the fields that
    // referenced a dead class but leave the class itself commented forever.
    for (final className in deadHere) {
      final planned = ModelFieldFixer.removeClasses(
        content: original,
        path: filePath,
        classNames: {className},
      );
      if (planned.edits.isEmpty) {
        continue;
      }

      if (!printedFile) {
        say(rel);
        say('');
        printedFile = true;
      }
      say('  💀 class $className (dead — taken whole)');
      say('');

      chosen.addAll(planned.edits);
      fieldRanges['$className|$_wholeClass'] = planned.edits;
      fieldsTouched++;
      partsTouched += planned.edits.length;
      for (final field in fileEntry.value[className]!) {
        handledKeys.add('$filePath|$className|${field.fieldName}');
      }
    }

    for (final classEntry in fileEntry.value.entries) {
      final className = classEntry.key;

      // Already removed wholesale above.
      if (deadHere.contains(className)) {
        continue;
      }

      // Fields taken in full are planned together in one pass. Operator chains
      // (`==`, `hashCode`) can only be cut correctly when the planner knows
      // every operand that is going; unioning independent single-field plans
      // would leave dangling `&&` / `^` operators.
      final wholeFields = <String>{
        for (final field in classEntry.value)
          if (selection.selectsWholeField(className, field.fieldName))
            field.fieldName,
      };

      if (wholeFields.isNotEmpty) {
        removedByClass
            .putIfAbsent(className, () => <String>{})
            .addAll(wholeFields);
        classFile[className] = filePath;

        final combined = ModelFieldFixer.removeFields(
          content: original,
          path: filePath,
          className: className,
          fieldNames: wholeFields,
        );
        if (combined.error == null) {
          chosen.addAll(combined.edits);
        }
      }

      for (final field in classEntry.value) {
        final plan = _plan(original, filePath, className, field.fieldName);
        final selected = selectedEdits(className, field.fieldName, plan, selection);

        if (selected.isEmpty) {
          continue;
        }

        if (plan.isEmpty) {
          skipped.add('$className.${field.fieldName}');
          continue;
        }

        if (!printedFile) {
          say(rel);
          say('');
          printedFile = true;
        }

        final whole = selected.length == plan.length;
        say('  $className.${field.fieldName}'
            '${whole ? '' : '  (${selected.length} of ${plan.length} parts)'}');

        final width = selected
            .map((e) => e.label.length)
            .reduce((a, b) => a > b ? a : b);
        for (final edit in selected) {
          say('    · ${edit.label.padRight(width)}   line ${edit.line}');
        }
        say('');

        // Whole-field edits already came from the combined plan above.
        if (!wholeFields.contains(field.fieldName)) {
          chosen.addAll(selected);
        }
        handledKeys.add('$filePath|$className|${field.fieldName}');
        fieldRanges['$className|${field.fieldName}'] = selected;
        fieldsTouched++;
        partsTouched += selected.length;
      }
    }

    if (chosen.isEmpty) {
      continue;
    }

    final applied =
        ModelFieldFixer.applyEditsDetailed(original, chosen, mode);
    if (applied.content != original) {
      originals[filePath] = original;
      await file.writeAsString(applied.content);
      modifiedFiles.add(filePath);

      // Attribute each commented range to the field whose edits produced it,
      // so `--undo` and `--remove` know exactly what to look for.
      if (mode == EditMode.comment) {
        final rank = _rankByText(applied.commented, original);
        for (final entry in fieldRanges.entries) {
          final parts = entry.key.split('|');
          // One entry per commented range, anchored and never deduplicated: a
          // field routinely contributes two ranges with identical text, and
          // collapsing them leaves the second commented for good with the
          // record cleared as though it had been restored.
          final snippets = <DisabledSnippet>[
            for (final range in applied.commented)
              if (entry.value.any(
                  (e) => e.start < range.end && e.end > range.start))
                DisabledSnippet(range.text, occurrence: rank[range.start]),
          ];
          if (snippets.isNotEmpty) {
            disabled.add(DisabledField(
              className: parts[0],
              fieldName: parts[1],
              filePath: filePath,
              snippets: snippets,
              disabledAt: DateTime.now(),
            ));
          }
        }
      }
    }
  }

  // --- Subclasses in other files ------------------------------------------
  //
  // `removeFields` works on one compilation unit, so it can only reach a
  // subclass declared beside its superclass. A subclass in another file
  // forwards the field through `super.field` just the same, and that stops
  // resolving the moment the superclass drops it. Because it is a resolution
  // error rather than a syntax one, nothing short of `dart analyze` sees it —
  // which would mean the whole apply reverting for a fix that is perfectly
  // mechanical.
  if (subclassLinks.isNotEmpty && removedByClass.isNotEmpty) {
    // Where each class is declared, so a subclass sitting in the same file as
    // its superclass can be skipped — that one is already planned.
    final declaredIn = <String, String>{...classFile};
    for (final link in subclassLinks) {
      declaredIn.putIfAbsent(link.className, () => link.filePath);
    }

    // A subclass of a subclass forwards the field on again, so widen the map
    // of affected classes until it stops growing.
    final affected = <String, Set<String>>{
      for (final entry in removedByClass.entries) entry.key: {...entry.value},
    };
    var growing = true;
    while (growing) {
      growing = false;
      for (final link in subclassLinks) {
        final inherited = affected[link.superName];
        if (inherited == null) {
          continue;
        }
        final carried = affected.putIfAbsent(link.className, () => <String>{});
        final before = carried.length;
        carried.addAll(inherited);
        if (carried.length != before) {
          growing = true;
        }
      }
    }

    final forwardedByFile = <String, Map<String, Set<String>>>{};
    for (final link in subclassLinks) {
      final inherited = affected[link.superName];
      if (inherited == null || inherited.isEmpty) {
        continue;
      }
      final superFile = declaredIn[link.superName];
      if (superFile == null || superFile == link.filePath) {
        continue;
      }
      forwardedByFile
          .putIfAbsent(link.filePath, () => {})
          .putIfAbsent(link.superName, () => <String>{})
          .addAll(inherited);
    }

    for (final entry in forwardedByFile.entries) {
      final filePath = entry.key;
      final file = File(filePath);
      if (!file.existsSync()) {
        continue;
      }

      // Planned against what is on disk now: this file may already have been
      // rewritten above, which would have moved every offset.
      final current = await file.readAsString();
      final plan = ModelFieldFixer.removeSuperForwarding(
        content: current,
        path: filePath,
        forwarded: entry.value,
      );
      if (plan.edits.isEmpty) {
        continue;
      }

      say(p.relative(filePath, from: projectRoot));
      say('');
      say('  ↑ forwards ${entry.value.entries.map((e) =>
          '${e.key}.{${e.value.join(', ')}}').join(', ')}');

      final width = plan.edits
          .map((e) => e.label.length)
          .reduce((a, b) => a > b ? a : b);
      for (final edit in plan.edits) {
        say('    · ${edit.label.padRight(width)}   line ${edit.line}');
      }
      say('');

      final applied =
          ModelFieldFixer.applyEditsDetailed(current, plan.edits, mode);
      if (applied.content == current) {
        continue;
      }

      // `current` is the true original only if nothing rewrote this file
      // earlier; if something did, the original is already recorded.
      originals.putIfAbsent(filePath, () => current);
      await file.writeAsString(applied.content);
      if (!modifiedFiles.contains(filePath)) {
        modifiedFiles.add(filePath);
      }
      partsTouched += plan.edits.length;

      // `--undo` has to put these back too, or restoring the superclass field
      // would leave the subclass forwarding a parameter that is commented out
      // on the other side.
      if (mode == EditMode.comment) {
        final rank = _rankByText(applied.commented, current);
        for (final superEntry in entry.value.entries) {
          for (final fieldName in superEntry.value) {
            // A cut that names no field at all is the one that takes a whole
            // optional group — it belongs to every field inside it.
            bool belongs(Edit edit) =>
                edit.label.endsWith(' $fieldName') ||
                !superEntry.value.any((f) => edit.label.endsWith(' $f'));

            // One entry per commented range, like the main loop: ranges are
            // walked once so overlapping edits cannot inflate the list, and
            // two ranges that happen to read the same both survive.
            final snippets = <DisabledSnippet>[
              for (final range in applied.commented)
                if (plan.edits
                    .where(belongs)
                    .any((e) => e.start < range.end && e.end > range.start))
                  DisabledSnippet(range.text, occurrence: rank[range.start]),
            ];

            if (snippets.isNotEmpty) {
              disabled.add(DisabledField(
                className: superEntry.key,
                fieldName: fieldName,
                filePath: filePath,
                snippets: snippets,
                disabledAt: DateTime.now(),
              ));
            }
          }
        }
      }
    }
  }

  if (modifiedFiles.isEmpty) {
    say('No files were modified.');
    return ApplySummary(
      modifiedFiles: const [],
      fieldsTouched: 0,
      partsTouched: 0,
      skipped: skipped,
    );
  }

  // Safety net. Model classes come in shapes this tool does not fully
  // understand (private fields behind getters, constructor-body assignment,
  // `map['k'] = _v` serialization). If an edit leaves the analyzer unhappy,
  // put every file back rather than hand over code that does not compile.
  if (verify) {
    final broke = await analysisErrors(projectRoot, modifiedFiles);
    if (broke == null || broke.isNotEmpty) {
      for (final entry in originals.entries) {
        await File(entry.key).writeAsString(entry.value);
      }
      say('');
      if (broke == null) {
        say('Reverted: could not verify the edit with `dart analyze`.');
      } else {
        say('Reverted: the edit introduced '
            '${broke.length} analyzer error${broke.length == 1 ? '' : 's'}.');
        say('');
        for (final line in broke.take(5)) {
          say('  $line');
        }
        if (broke.length > 5) {
          say('  … and ${broke.length - 5} more');
        }
      }
      say('');
      say('No files were changed. This usually means the model uses a shape '
          'the fixer does not handle yet — please report it.');
      return ApplySummary(
        modifiedFiles: const [],
        fieldsTouched: 0,
        partsTouched: 0,
        skipped: skipped,
        revertedFiles: modifiedFiles,
      );
    }
  }

  say('$verb $partsTouched part${partsTouched == 1 ? '' : 's'} '
      'across $fieldsTouched field${fieldsTouched == 1 ? '' : 's'} '
      'in ${modifiedFiles.length} file${modifiedFiles.length == 1 ? '' : 's'}.');

  // Deleting code can strand an import or empty a file outright. Commenting
  // it out cannot — everything is still there, just inert — so this runs for
  // `remove` only.
  var cleanedFiles = modifiedFiles;
  if (mode == EditMode.delete) {
    final cleanup = await cleanupAfterRemoval(
      projectRoot: projectRoot,
      modifiedFiles: modifiedFiles,
      restoreOnFailure: originals,
      log: say,
    );
    if (!cleanup.isEmpty) {
      say('Cleaned up ${cleanup.importsStrippedFrom.length} import'
          '${cleanup.importsStrippedFrom.length == 1 ? '' : 's'} and deleted '
          '${cleanup.deletedFiles.length} empty '
          'file${cleanup.deletedFiles.length == 1 ? '' : 's'}.');
      cleanedFiles = [
        for (final f in modifiedFiles)
          if (!cleanup.deletedFiles.contains(f)) f,
      ];

      // Re-verify: stripping an import can leave a name unresolved. Deleting
      // a file cannot break an importer, because cleanup refuses to delete
      // one anything still imports — which is what keeps this check, over the
      // files we edited, sufficient.
      final after = await analysisErrors(projectRoot, cleanedFiles);
      if (after == null || after.isNotEmpty) {
        for (final entry in originals.entries) {
          await File(entry.key).writeAsString(entry.value);
        }
        say('Reverted: cleanup did not verify.');
        return ApplySummary(
          modifiedFiles: const [],
          fieldsTouched: 0,
          partsTouched: 0,
          skipped: skipped,
          revertedFiles: modifiedFiles,
        );
      }
    }
  }

  if (runFormat) {
    final result = await Process.run(
      'dart',
      ['format', ...cleanedFiles],
      workingDirectory: projectRoot,
      runInShell: true,
    );
    if (result.exitCode != 0) {
      stderr.writeln('dart format failed:\n${result.stderr}');
    } else {
      say('Formatted ${cleanedFiles.length} '
          'file${cleanedFiles.length == 1 ? '' : 's'}.');
    }
  }

  return ApplySummary(
    modifiedFiles: modifiedFiles,
    fieldsTouched: fieldsTouched,
    partsTouched: partsTouched,
    skipped: skipped,
    handledKeys: handledKeys,
    disabled: disabled,
  );
}

/// The edits of [plan] that [selection] covers.
///
/// Selecting the field declaration promotes the whole field: once the
/// declaration is gone, nothing else may still reference it.
List<Edit> selectedEdits(
  String className,
  String fieldName,
  List<Edit> plan,
  Selection selection,
) {
  if (plan.isEmpty) {
    return const [];
  }

  if (selection.selectsWholeField(className, fieldName)) {
    return plan;
  }

  final indices = <int>[];
  for (var i = 0; i < plan.length; i++) {
    if (selection.selectsPart(className, fieldName, i)) {
      indices.add(i);
    }
  }

  if (indices.isEmpty) {
    return const [];
  }

  final promotes = indices.any(
    (i) => plan[i].label.startsWith('field declaration'),
  );

  return promotes ? plan : [for (final i in indices) plan[i]];
}

List<Edit> _plan(
  String content,
  String path,
  String className,
  String fieldName,
) {
  try {
    return ModelFieldFixer.removeFields(
      content: content,
      path: path,
      className: className,
      fieldNames: {fieldName},
    ).edits;
  } catch (_) {
    return const [];
  }
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


/// Analyzer errors in [files] after an edit.
///
/// Returns null when verification could not be performed at all — callers
/// treat that as a failure and revert, because writing code we could not
/// check is exactly how broken edits reach the working tree.
Future<List<String>?> analysisErrors(
  String projectRoot,
  List<String> files,
) async {
  if (files.isEmpty) {
    return const [];
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
    return null;
  }

  final output = '${result.stdout}${result.stderr}';

  // A usage error means the analyzer never ran; do not read that as "clean".
  if (output.contains('Usage: dart analyze')) {
    return null;
  }

  if (result.exitCode == 0) {
    return const [];
  }

  // A non-zero exit can just mean warnings or infos, which are not our
  // problem. Only error-severity diagnostics mean the edit broke the code.
  return output
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.startsWith('error'))
      .toList();
}
