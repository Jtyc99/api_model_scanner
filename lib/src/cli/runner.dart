import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../apply_runner.dart';
import '../cache/disabled_plan.dart';
import '../cache/disabled_store.dart';
import '../cache/selection.dart';
import '../cache/unused_cache.dart';
import '../version.dart';
import 'config.dart';
import 'gui.dart';
import '../model.dart';
import '../model_field_fixer.dart';
import '../scanning/dead_classes.dart';
import '../scanning/model_discovery.dart';
import '../scanning/unused_scanner.dart';
import 'editor.dart';
import 'prompt.dart';

/// Version reported by `--version`. Keep in sync with pubspec.yaml.


/// Parses [arguments] and runs the matching command. Returns a process exit
/// code; never throws for ordinary usage errors.
Future<int> runCli(List<String> arguments) async {
  final runner = ApiModelScannerRunner();

  try {
    return await runner.run(arguments) ?? 0;
  } on UsageException catch (e) {
    stderr.writeln(e.message);
    stderr.writeln('');
    stderr.writeln(e.usage);
    return 64;
  } on ModelsDirectoryNotSet {
    stderr.writeln('No models directory is set.');
    stderr.writeln('');
    stderr.writeln(
      'Run this once, pointing at the folder that holds your API model '
      'classes:',
    );
    stderr.writeln('  amscan set-default lib/server/response');
    stderr.writeln('');
    stderr.writeln('Add --project to set it for this project only, '
        'or pass --models=<dir> for a single run.');
    return 78;
  } on ModelsDirectoryNotFound catch (e) {
    stderr.writeln(e.toString());
    stderr.writeln(
      'Set it with `amscan set-default <dir>`, '
      'or pass --models=<dir> for a single run.',
    );
    return 66;
  } on NotADartFile catch (e) {
    stderr.writeln(e.toString());
    stderr.writeln(
      'Pass a directory of model classes, or one `.dart` file.',
    );
    return 66;
  }
}

class ApiModelScannerRunner extends CommandRunner<int> {
  ApiModelScannerRunner()
      : super(
          'api_model_scanner',
          'Find and remove API model fields that your app never uses.\n\n'
              'Run this from the root of the project you want to analyze.',
        ) {
    argParser.addFlag(
      'version',
      negatable: false,
      help: 'Print the tool version and exit.',
    );
    addCommand(SetDefaultCommand());
    addCommand(GuiCommand());
    addCommand(ScanCommand());
    addCommand(RemoveCommand());
    addCommand(DisableCommand());
    addCommand(ClearCommand());
  }

  @override
  Future<int?> runCommand(ArgResults topLevelResults) async {
    if (topLevelResults['version'] as bool) {
      stdout.writeln('api_model_scanner $packageVersion');
      return 0;
    }
    return super.runCommand(topLevelResults);
  }
}

/// Shared plumbing: `--models`, the cache, and the scan step.
abstract class _ModelCommand extends Command<int> {
  _ModelCommand() {
    argParser.addOption(
      'models',
      help: 'Directory of API model classes — or a single `.dart` file — '
          'relative to the project root. Overrides the remembered default '
          'for this run.',
      valueHelp: 'dir',
    );
  }

  String get projectRoot => Directory.current.absolute.path;

  String? _models;

  /// The directory being scanned. Only valid once [resolveModels] has run.
  String get modelsPath => _models!;

  /// Offers the VS Code editor the first time, and remembers the answer.
  ///
  /// This is as close as a Dart package can get to asking at install time:
  /// pub runs nothing on `activate`, by design, so the first command that
  /// produces something worth looking at has to do the asking. Silence is
  /// treated as no — an editor extension should never arrive uninvited.
  void maybeOfferGui() {
    if (ModelsConfig.readGuiPreference() != null) {
      return; // Already answered; `amscan gui` changes it.
    }
    if (!canPrompt || !codeCliAvailable() || guiInstalled()) {
      return;
    }

    say('');
    say('There is a VS Code editor for this report: a real table with '
        'checkbox cells, instead of a Markdown list.');
    say('');

    final choice = selectSingle('  Install it?', [
      'No — the Markdown report is fine',
      'Yes — install it now',
    ]);

    if (choice != 1) {
      ModelsConfig.writeGuiPreference(false);
      say('');
      say('Skipped. Run `amscan gui install` if you change your mind.');
      say('');
      return;
    }

    final result = installGui();
    ModelsConfig.writeGuiPreference(result.ok);
    say('');
    if (result.ok) {
      say('Installed $extensionId. Reload the VS Code window to use it.');
    } else {
      say('Could not install it; the Markdown report still works. '
          'Try `amscan gui install` for the details.');
    }
    say('');
  }

  /// Works out which directory to scan.
  ///
  /// Throws [ModelsDirectoryNotSet] when nothing is configured. There is
  /// deliberately no fallback: scanning everything under `lib` would treat
  /// every class in the app as an API model, and the fields it then reported
  /// would be wrong in a way that is expensive to notice. Naming the
  /// directory is a one-off, so requiring it costs less than guessing.
  Future<void> resolveModels() async {
    if (argResults!.wasParsed('models')) {
      _models = p.normalize(
        p.join(projectRoot, argResults!['models'] as String),
      );
      return;
    }

    final configured = ModelsConfig.resolve(projectRoot);
    if (configured == null) {
      throw const ModelsDirectoryNotSet();
    }

    _models = configured.absolute(projectRoot);
  }

  CacheStore get cache => CacheStore(projectRoot);

  void say(String message) => stdout.writeln(message);

  void printHeader(String title) {
    say('');
    say(title);
    say('=' * title.length);
    say('');
    say('Project: $projectRoot');
    // Absent on the paths that work from the disabled record rather than by
    // scanning, where naming a models directory would only mislead.
    if (_models != null) {
      say('Models:  ${p.relative(modelsPath, from: projectRoot)}');
    }
    say('');
  }

  /// Runs a full scan and writes the cache.
  Future<UnusedCache> scanAndCache() async {
    final discovered = await findModels(modelsPath: modelsPath);
    final fields = discovered.fields;

    say('Found ${fields.length} model fields '
        'in ${discovered.classes.length} classes.');

    // Worth saying out loud: a class without `fromJson`/`toJson` is not one
    // this tool can reason about, and silently ignoring it would read as
    // "nothing unused here".
    if (discovered.skipped.isNotEmpty) {
      final names = discovered.skipped.take(3).join(', ');
      say('Skipped ${discovered.skipped.length} '
          'class${discovered.skipped.length == 1 ? '' : 'es'} with no '
          '`fromJson`/`toJson` ($names'
          '${discovered.skipped.length > 3 ? ', …' : ''}).');
    }

    final sink = stdout;

    // The in-place progress line only makes sense on a terminal; when piped
    // it would just fill the log with control characters.
    final showProgress = stdout.hasTerminal;

    final report = fields.isEmpty
        ? const UsageReport(fields: [], classReferences: {})
        : await analyzeUsage(
            projectRoot: projectRoot,
            fields: fields,
            classes: discovered.classes,
            onStatus: say,
            onProgress: !showProgress
                ? null
                : (done, total, field) {
                    sink.write(
                      '\r\x1b[2KScanning $done/$total: '
                      '${field.className}.${field.fieldName}',
                    );
                  },
            onClassProgress: !showProgress
                ? null
                : (done, total, model) {
                    sink.write(
                      '\r\x1b[2KResolving class $done/$total: '
                      '${model.className}',
                    );
                  },
          );

    final usages = report.fields;

    if (fields.isNotEmpty && showProgress) {
      sink.write('\r\x1b[2K');
    }

    final unused = usages
        .where((u) => u.isPotentiallyUnused)
        .map((u) => CachedField.fromModelField(u.field))
        .toList();

    // Work out which classes die once the unused fields are gone. This needs
    // the removal ranges, because a field's own type annotation is a reference
    // to its class — `Job? job;` keeps `Job` alive until that line is deleted.
    final deadClasses = _resolveDead(
      classes: discovered.classes,
      unused: unused,
      classReferences: report.classReferences,
    );

    if (deadClasses.isNotEmpty) {
      say('${deadClasses.length} class${deadClasses.length == 1 ? '' : 'es'} '
          'dead outright: '
          '${deadClasses.keys.map((k) => k.split('|').last).join(', ')}');
    }

    final result = UnusedCache(
      scannedAt: DateTime.now(),
      projectRoot: projectRoot,
      modelsPath: modelsPath,
      totalFieldsScanned: fields.length,
      fields: unused,
      deadClasses: deadClasses,
    );

    cache.write(result);
    return result;
  }

  /// Computes each unused field's removal ranges, then iterates the dead-class
  /// fixpoint over them.
  Map<String, Set<String>> _resolveDead({
    required List<ModelClass> classes,
    required List<CachedField> unused,
    required Map<String, List<ClassReference>> classReferences,
  }) {
    final ranges = <RemovalRange>[];

    final byFile = <String, List<CachedField>>{};
    for (final field in unused) {
      byFile.putIfAbsent(field.filePath, () => []).add(field);
    }

    for (final entry in byFile.entries) {
      final file = File(entry.key);
      if (!file.existsSync()) {
        continue;
      }
      final content = file.readAsStringSync();
      for (final field in entry.value) {
        try {
          final plan = ModelFieldFixer.removeFields(
            content: content,
            path: entry.key,
            className: field.className,
            fieldNames: {field.fieldName},
          );
          for (final edit in plan.edits) {
            ranges.add(RemovalRange(
              filePath: entry.key,
              start: edit.start,
              end: edit.end,
              fieldKey: '${classKey(entry.key, field.className)}'
                  '.${field.fieldName}',
            ));
          }
        } catch (_) {
          // A field we cannot plan simply contributes no range.
        }
      }
    }

    return resolveDeadClasses(
      classes: classes,
      unusedFieldKeys: {
        for (final f in unused) '${f.className}.${f.fieldName}',
      },
      classReferences: classReferences,
      fieldRemovals: ranges,
    );
  }
}

/// `amscan scan`
class ScanCommand extends _ModelCommand {
  ScanCommand() {
    argParser
      ..addFlag(
        'rescan',
        help: 'Skip the cached-results prompt. --rescan forces a fresh scan, '
            '--no-rescan keeps the existing report.',
        defaultsTo: null,
      )
      ..addFlag(
        'open',
        defaultsTo: true,
        help: 'Open the generated report in your editor.',
      );
  }

  @override
  String get name => 'scan';

  @override
  String get description =>
      'Scan for unused model fields and write a report you can tick.';

  @override
  Future<int> run() async {
    final shouldOpen = argResults!['open'] as bool;

    await resolveModels();

    printHeader('API Model Field Scanner');

    final existing = cache.read();

    if (existing != null) {
      say('Cached results found — scanned ${existing.age}, '
          '${existing.fields.length} potentially unused.');
      say('');

      final flag = argResults!['rescan'] as bool?;
      final rescan = flag ??
          (!canPrompt ||
              selectSingle('  Rescan the project?', [
                    'Yes — rescan now (replaces the cached report)',
                    'No — keep the existing report',
                  ]) ==
                  0);

      if (!rescan) {
        say('Keeping the existing report:');
        say('  ${cache.reportPath}');
        say('');
        // Declining a rescan still means "show me the results".
        if (shouldOpen && openInEditor(cache.reportPath) == null) {
          say('Could not open an editor automatically — open the path above.');
          say('');
        }
        return 0;
      }
    }

    final result = await scanAndCache();

    if (result.fields.isEmpty) {
      say('No unused model fields found.');
      say('');
      return 0;
    }

    final classes = result.fields.map((f) => f.className).toSet().length;
    say('${result.fields.length} potentially unused '
        'field${result.fields.length == 1 ? '' : 's'} '
        'across $classes class${classes == 1 ? '' : 'es'}.');
    say('');
    say('Report written to:');
    say('  ${cache.reportPath}');
    say('');

    maybeOfferGui();

    if (shouldOpen && openInEditor(cache.reportPath) == null) {
      say('Could not open an editor automatically — open the path above.');
      say('');
    }

    say('Tick what you want, then run `amscan remove` or `amscan disable`.');
    say('');

    return 0;
  }
}

/// Shared behaviour for the two commands that rewrite source.
abstract class _MutatingCommand extends _ModelCommand {
  _MutatingCommand() {
    argParser
      ..addFlag(
        'format',
        defaultsTo: true,
        help: 'Run `dart format` on the files that were modified. Skipped '
            'while any code is commented out, since formatting around a '
            'comment can drop a separator that `--undo` needs.',
      )
      ..addFlag(
        'force',
        negatable: false,
        help: 'Allow a dirty git working tree. On remove/disable this also '
            'offers a rescan first, since the sources may have moved. '
            '--undo never needs it.',
      )
      ..addFlag(
        'all',
        negatable: false,
        help: 'Act on every unused field without prompting, ignoring ticks.',
      );
  }

  EditMode get mode;

  /// Imperative verb used in the "nothing is ticked" prompt.
  String get verb;

  @override
  Future<int> run() async {
    await resolveModels();

    printHeader(
      'API Model Field ${mode == EditMode.delete ? 'Remover' : 'Disabler'}',
    );

    final force = argResults!['force'] as bool;

    // Without --force the tree must be clean — which is also why no rescan
    // prompt is needed: the sources cannot have changed since the scan.
    if (!force) {
      final dirty = await gitWorkingTreeDirty(projectRoot);
      if (dirty == true) {
        stderr.writeln(
          'Refusing to write: the git working tree is not clean.\n'
          'Commit or stash your changes first, or pass --force.',
        );
        return 1;
      }
    }

    var result = cache.read();

    if (result == null) {
      result = await scanAndCache();
    } else if (force) {
      // --force permits a dirty tree, so the cache may be out of date.
      say('Cached results found — scanned ${result.age}, '
          '${result.fields.length} potentially unused.');
      say('');
      final rescan = !canPrompt ||
          selectSingle('  Rescan before writing?', [
                'Yes — rescan first (the tree may have changed)',
                'No — use the cached report',
              ]) ==
              0;
      if (rescan) {
        result = await scanAndCache();
      }
    }

    if (result.fields.isEmpty) {
      say('No unused model fields recorded. Nothing to do.');
      say('');
      return 0;
    }

    final selection = _resolveSelection(result);
    if (selection == null) {
      say('Nothing selected. Exiting without changes.');
      say('');
      return 0;
    }

    // Subclasses forward removed fields through `super.field`, and routinely
    // live in another file than the class they extend — so the per-file fixer
    // cannot find them without this index. Built from the path that was
    // actually scanned, not the flag, which may have drifted since. Failing
    // to build it must not sink the apply: without it, same-file subclasses
    // are still handled and anything else is caught by the safety net.
    var subclassLinks = const <SubclassLink>[];
    try {
      subclassLinks = await findSubclassLinks(modelsPath: result.modelsPath);
    } on Object {
      subclassLinks = const [];
    }

    final summary = await applySelection(
      projectRoot: projectRoot,
      fields: result.fields,
      selection: selection,
      mode: mode,
      runFormat: argResults!['format'] as bool,
      deadClasses: result.deadClasses,
      subclassLinks: subclassLinks,
      log: say,
    );

    if (summary.skipped.isNotEmpty) {
      say('');
      say('Skipped ${summary.skipped.length}: ${summary.skipped.join(', ')}');
    }

    if (summary.modifiedFiles.isNotEmpty) {
      // Keep the report alive for whatever is still outstanding, rather than
      // throwing away ticks for fields that were never touched.
      final remaining = result.fields
          .where((f) => !summary.handledKeys
              .contains('${f.filePath}|${f.className}|${f.fieldName}'))
          .toList();

      if (remaining.isEmpty) {
        cache.delete();
        say('');
        say('All recorded fields handled — report cleared.');
      } else {
        cache.write(UnusedCache(
          scannedAt: result.scannedAt,
          projectRoot: result.projectRoot,
          modelsPath: result.modelsPath,
          totalFieldsScanned: result.totalFieldsScanned,
          fields: remaining,
        ));
        say('');
        say('${remaining.length} field${remaining.length == 1 ? '' : 's'} '
            'still listed in the report.');
      }

      if (summary.disabled.isNotEmpty) {
        DisabledStore(projectRoot).add(summary.disabled);
        say('Recorded in ${DisabledStore(projectRoot).reportPath}');
        say('Undo with `amscan disable --undo`, '
            'or delete for good with `amscan disable --remove`.');
      }

      say('Review with `git diff`.');
    }

    say('');
    return 0;
  }

  /// Reads the ticks from the report, falling back to a prompt when nothing
  /// is selected. Returns null when the user declines.
  Selection? _resolveSelection(UnusedCache result) {
    if (argResults!['all'] as bool) {
      return const Selection(all: true);
    }

    final selection = cache.readSelection();
    if (selection.isNotEmpty) {
      say('Using ${selection.markedCount} selection'
          '${selection.markedCount == 1 ? '' : 's'} from the report.');
      say('');
      return selection;
    }

    final count = result.fields.length;
    say('Nothing is ticked in the report:');
    say('  ${cache.reportPath}');
    say('');

    if (!canPrompt) {
      stderr.writeln(
        'Nothing selected and no terminal to ask on. '
        'Pass --all to act on every unused field.',
      );
      return null;
    }

    final choice = selectSingle(
      '  $verb all $count unused field${count == 1 ? '' : 's'}?',
      [
        'No — exit so I can tick some first',
        'Yes — apply to everything',
      ],
    );

    return choice == 1 ? const Selection(all: true) : null;
  }
}

/// `amscan remove`
class RemoveCommand extends _MutatingCommand {
  @override
  String get name => 'remove';

  @override
  String get description =>
      'Delete the selected unused fields using AST-aware source edits.';

  @override
  EditMode get mode => EditMode.delete;

  @override
  String get verb => 'Remove';
}

/// `amscan disable`
class DisableCommand extends _MutatingCommand {
  DisableCommand() {
    argParser
      ..addFlag(
        'undo',
        negatable: false,
        help: 'Re-enable previously disabled fields (uncomment them).',
      )
      ..addFlag(
        'remove',
        negatable: false,
        help: 'Delete previously disabled fields for good.',
      );
  }

  @override
  String get name => 'disable';

  @override
  String get description =>
      'Comment out the selected unused fields instead of deleting them.';

  @override
  EditMode get mode => EditMode.comment;

  @override
  String get verb => 'Disable';

  @override
  Future<int> run() async {
    final undo = argResults!['undo'] as bool;
    final promote = argResults!['remove'] as bool;

    if (undo && promote) {
      stderr.writeln('Pass either --undo or --remove, not both.');
      return 64;
    }

    if (!undo && !promote) {
      return super.run();
    }

    return _applyToDisabled(restore: undo);
  }

  /// Ticks from `disabled_fields.md`, or a prompt when nothing is ticked.
  /// Returns null when the user declines.
  Selection? _selectDisabled(
    DisabledStore store,
    List<DisabledField> all, {
    required bool restore,
  }) {
    if (argResults!['all'] as bool) {
      return const Selection(all: true);
    }

    final selection = store.readSelection();
    if (selection.isNotEmpty) {
      say('Using ${selection.markedCount} selection'
          '${selection.markedCount == 1 ? '' : 's'} from the record.');
      say('');
      return selection;
    }

    say('Nothing is ticked in the record:');
    say('  ${store.reportPath}');
    say('');

    if (!canPrompt) {
      stderr.writeln(
        'Nothing selected and no terminal to ask on. '
        'Pass --all to act on every disabled field.',
      );
      return null;
    }

    final choice = selectSingle(
      '  ${restore ? 'Re-enable' : 'Remove'} all ${all.length} '
      'disabled field${all.length == 1 ? '' : 's'}?',
      [
        'No — exit so I can tick some first',
        'Yes — apply to everything',
      ],
    );

    return choice == 1 ? const Selection(all: true) : null;
  }

  /// Acts on the already-disabled record: puts the code back (`--undo`) or
  /// deletes it outright (`--remove`).
  Future<int> _applyToDisabled({required bool restore}) async {
    // The record names every file it touches, so this path needs no models
    // directory — and asking for one when undoing would be a poor welcome.
    printHeader(
      restore ? 'API Model Field Re-enabler' : 'API Model Field Remover',
    );

    final store = DisabledStore(projectRoot);
    final all = store.read();

    if (all.isEmpty) {
      say('Nothing is disabled.');
      say('');
      return 0;
    }

    // Same selection contract as the unused report: ticks win, and with
    // nothing ticked we ask before touching everything.
    final selection = _selectDisabled(store, all, restore: restore);
    if (selection == null) {
      say('Nothing selected. Exiting without changes.');
      say('');
      return 0;
    }

    // A whole-class record carries `(whole class)` as its field name and is
    // ticked like any other row; `selectsWholeField` already covers the
    // class-level and select-everything boxes above it.
    final recorded = all
        .where((f) =>
            selection.selectsWholeField(f.filePath, f.className, f.fieldName))
        .toList();

    if (recorded.isEmpty) {
      say('Nothing selected matches the record.');
      say('');
      return 0;
    }

    // `--undo` is deliberately exempt. The guard exists so a rewrite driven by
    // cached analysis can always be walked back with `git checkout` — but
    // `disable` dirties the tree by construction, so enforcing it here would
    // mean undo never runs without `--force`, precisely when it is most
    // wanted. Undo is also the one path that does not need it: it reads the
    // disabled record rather than the unused cache, so nothing can be stale;
    // it matches snippets verbatim and skips anything that has been edited;
    // and the `dart analyze` net below puts every file back if the result
    // does not hold up. `--remove` keeps the guard — it deletes code for
    // good, and is the only irreversible step here.
    if (!restore && !(argResults!['force'] as bool)) {
      final dirty = await gitWorkingTreeDirty(projectRoot);
      if (dirty == true) {
        stderr.writeln(
          'Refusing to write: the git working tree is not clean.\n'
          'Commit or stash your changes first, or pass --force.',
        );
        return 1;
      }
    }

    // Planned against every record for a file, not just the selected ones,
    // because ownership is what decides whether a range may move at all.
    final allByFile = <String, List<DisabledField>>{};
    for (final field in all) {
      allByFile.putIfAbsent(field.filePath, () => []).add(field);
    }

    final selectedKeys = {for (final field in recorded) field.key};

    final byFile = <String, List<DisabledField>>{};
    for (final field in recorded) {
      byFile.putIfAbsent(field.filePath, () => []).add(field);
    }

    final originals = <String, String>{};
    final changed = <String>[];
    final done = <String>{};

    for (final entry in byFile.entries) {
      final file = File(entry.key);
      if (!file.existsSync()) {
        say('  ! ${p.relative(entry.key, from: projectRoot)} no longer exists');
        continue;
      }

      final original = await file.readAsString();
      final rel = p.relative(entry.key, from: projectRoot);
      say(rel);
      say('');

      final plan = resolveDisabled(original, allByFile[entry.key]!);

      // A field moves whole or not at all. Restoring some of its ranges would
      // leave, say, a `fromJson` line naming a declaration that is still
      // commented out — which is why the record lists snippets without
      // checkboxes in the first place.
      //
      // A range several fields share can only move once every one of them is
      // going with it, and that spreads: a field held back by one shared
      // range pins every other range it owns, which can in turn hold back the
      // fields sharing those. Settle it before touching anything.
      final blockedBy = <String, Set<String>>{};
      final blocked = <String>{...plan.unresolved};
      for (final range in plan.ranges) {
        final missing = range.owners.difference(selectedKeys);
        if (missing.isEmpty) {
          continue;
        }
        for (final owner in range.owners.intersection(selectedKeys)) {
          blocked.add(owner);
          blockedBy
              .putIfAbsent(owner, () => <String>{})
              .addAll(missing.map((k) => k.split('|').last));
        }
      }

      var settling = true;
      while (settling) {
        settling = false;
        for (final range in plan.ranges) {
          if (!range.owners.any(blocked.contains)) {
            continue;
          }
          for (final owner in range.owners) {
            if (blocked.add(owner)) {
              settling = true;
            }
          }
        }
      }

      final moving = [
        for (final range in plan.ranges)
          if (range.owners.every(selectedKeys.contains) &&
              !range.owners.any(blocked.contains))
            range,
      ];

      final working = applyRanges(original, moving, restore: restore);

      for (final field in entry.value) {
        if (!blocked.contains(field.key)) {
          say('  ${restore ? '+' : '-'} '
              '${field.className}.${field.fieldName}');
          done.add(field.key);
          continue;
        }

        if (plan.unresolved.contains(field.key)) {
          say('  ! ${field.className}.${field.fieldName} — '
              'its commented code has changed, skipped');
        } else {
          final names = blockedBy[field.key];
          say('  ~ ${field.className}.${field.fieldName} — shares code with '
              '${names == null || names.isEmpty ? 'fields that are not ticked' : names.join(', ')}'
              '; tick those too');
        }
      }
      say('');

      if (working != original) {
        originals[entry.key] = original;
        await file.writeAsString(working);
        changed.add(entry.key);
      }
    }

    if (changed.isEmpty) {
      say('Nothing changed.');
      say('');
      return 0;
    }

    // Same safety net as the other mutating paths.
    final broke = await analysisErrors(projectRoot, changed);
    if (broke == null || broke.isNotEmpty) {
      for (final entry in originals.entries) {
        await File(entry.key).writeAsString(entry.value);
      }
      say('Reverted: the change did not verify with `dart analyze`.');
      for (final line in (broke ?? const <String>[]).take(5)) {
        say('  $line');
      }
      say('');
      return 1;
    }

    // Only once nothing is commented out anywhere: formatting around a
    // surviving comment can remove a separator that its undo still needs.
    if ((argResults!['format'] as bool) && !store.exists) {
      await Process.run(
        'dart',
        ['format', ...changed],
        workingDirectory: projectRoot,
        runInShell: true,
      );
    }

    store.remove(done);

    say('${restore ? 'Re-enabled' : 'Removed'} ${done.length} '
        'field${done.length == 1 ? '' : 's'} '
        'in ${changed.length} file${changed.length == 1 ? '' : 's'}.');
    if (!store.exists) {
      say('Nothing is disabled any more — record cleared.');
    }
    say('');
    return 0;
  }
}

/// `amscan gui`, `amscan gui install`, `amscan gui uninstall`
///
/// Pub runs nothing on `activate` or `deactivate` — a package may never
/// execute its own code as a side effect of being installed — so the editor
/// cannot ride along with either. These commands are how it is managed, and
/// [maybeOfferGui] is what makes the first run mention it at all.
class GuiCommand extends Command<int> {
  GuiCommand() {
    addSubcommand(_GuiInstallCommand());
    addSubcommand(_GuiUninstallCommand());
    addSubcommand(_GuiStatusCommand());
  }

  @override
  String get name => 'gui';

  @override
  String get description =>
      'Manage the VS Code editor that shows reports as a table.';

}

class _GuiStatusCommand extends Command<int> {
  @override
  String get name => 'status';

  @override
  String get description => 'Show whether the editor is installed.';

  @override
  Future<int> run() async {
    final stored = ModelsConfig.readGuiPreference();

    stdout.writeln('Editor: $extensionId');

    if (!codeCliAvailable()) {
      stdout.writeln('  The `code` command is not on PATH, so this cannot be '
          'managed from here.');
      stdout.writeln('  In VS Code: Command Palette → '
          '"Shell Command: Install \'code\' command in PATH".');
      return 0;
    }

    stdout.writeln(guiInstalled() ? '  Installed.' : '  Not installed.');
    stdout.writeln(switch (stored) {
      true => '  You asked for it to be installed.',
      false => '  You declined it; run `amscan gui install` to change that.',
      null => '  You have not been asked yet.',
    });
    return 0;
  }
}

class _GuiInstallCommand extends Command<int> {
  @override
  String get name => 'install';

  @override
  String get description => 'Install the VS Code editor for reports.';

  @override
  Future<int> run() async {
    final result = installGui();
    ModelsConfig.writeGuiPreference(result.ok);

    if (result.ok) {
      stdout.writeln(switch (result.source!) {
        GuiSource.marketplace => 'Installed $extensionId from the Marketplace.',
        GuiSource.bundled =>
          'Installed $extensionId from the copy shipped with this package.',
      });
      stdout.writeln('Reload the VS Code window for it to take effect '
          '(Command Palette → "Developer: Reload Window").');
      return 0;
    }

    switch (result.problem!) {
      case GuiProblem.noCodeCli:
        stderr.writeln('The `code` command is not on PATH.');
        stderr.writeln('In VS Code: Command Palette → '
            '"Shell Command: Install \'code\' command in PATH", then retry.');
      case GuiProblem.unavailable:
        stderr.writeln('Could not install $extensionId.');
        if (result.detail.isNotEmpty) {
          stderr.writeln(result.detail);
        }
        stderr.writeln('The Markdown report works without it.');
    }
    return 1;
  }
}

class _GuiUninstallCommand extends Command<int> {
  @override
  String get name => 'uninstall';

  @override
  String get description => 'Remove the VS Code editor for reports.';

  @override
  Future<int> run() async {
    // Recorded either way: `deactivate` cannot reach the editor, so the
    // answer has to survive for the next install to respect it.
    ModelsConfig.writeGuiPreference(false);

    if (uninstallGui()) {
      stdout.writeln('Removed $extensionId.');
      return 0;
    }

    stderr.writeln('Could not remove $extensionId — '
        'it may not be installed, or `code` is not on PATH.');
    return 1;
  }
}

/// `amscan set-default <dir>`
class SetDefaultCommand extends Command<int> {
  SetDefaultCommand() {
    argParser.addFlag(
      'project',
      negatable: false,
      help: 'Remember it for this project only, instead of machine-wide. '
          'A project setting wins over the machine-wide one.',
    );
  }

  @override
  String get name => 'set-default';

  @override
  String get description =>
      'Remember the directory that holds your API model classes.';

  @override
  String get invocation => 'api_model_scanner set-default <dir>';

  @override
  Future<int> run() async {
    final rest = argResults!.rest;

    if (rest.length != 1 || rest.single.trim().isEmpty) {
      stderr.writeln('Usage: amscan set-default <dir>');
      stderr.writeln('For example: amscan set-default lib/server/response');
      return 64;
    }

    final projectRoot = Directory.current.absolute.path;
    final forProject = argResults!['project'] as bool;

    // Stored relative so the setting means the same thing in any checkout,
    // and so a machine-wide default can apply across projects at all.
    final relative = p.normalize(
      p.isAbsolute(rest.single)
          ? p.relative(rest.single, from: projectRoot)
          : rest.single,
    );

    if (relative.startsWith('..')) {
      stderr.writeln('That directory is outside the project: ${rest.single}');
      return 64;
    }

    final target = p.join(projectRoot, relative);
    if (!Directory(target).existsSync() && !File(target).existsSync()) {
      // Not fatal for a machine-wide default — the point is other projects —
      // but silence here would hide a typo until the next scan.
      stderr.writeln('Warning: $relative does not exist in this project.');
    }

    if (forProject) {
      ModelsConfig.writeProject(projectRoot, relative);
      stdout.writeln('Default models directory for this project: $relative');
      stdout.writeln('  ${ModelsConfig.projectPath(projectRoot)}');
    } else {
      ModelsConfig.writeGlobal(relative);
      stdout.writeln('Default models directory for every project: $relative');
      stdout.writeln('  ${ModelsConfig.globalPath()}');

      final override = ModelsConfig.readProject(projectRoot);
      if (override != null && override != relative) {
        stdout.writeln('');
        stdout.writeln('Note: this project overrides it with `$override`. '
            'Run with --project to change that instead.');
      }
    }

    return 0;
  }
}

/// `amscan clear`
class ClearCommand extends Command<int> {
  @override
  String get name => 'clear';

  @override
  String get description =>
      'Delete the cached scan results and report for this project.';

  @override
  Future<int> run() async {
    final store = CacheStore(Directory.current.absolute.path);

    final removed = store.clearAll();

    if (removed.isEmpty) {
      stdout.writeln('No cache to clear (${store.directory}).');
      return 0;
    }

    stdout.writeln('Cleared ${removed.length} '
        'file${removed.length == 1 ? '' : 's'} from ${store.directory}:');
    for (final path in removed) {
      stdout.writeln('  - ${p.basename(path)}');
    }
    return 0;
  }
}
