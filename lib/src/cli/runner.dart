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
import 'init.dart';
import 'uninstall.dart';
import '../model.dart';
import '../model_field_fixer.dart';
import '../scanning/dead_classes.dart';
import '../scanning/model_discovery.dart';
import '../scanning/unused_scanner.dart';
import 'editor.dart';
import 'prompt.dart';
import 'style.dart';

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
  } on ModelsDirectoryNotSet catch (e) {
    e.guidance.forEach(stderr.writeln);
    return 78;
  } on ModelsDirectoryNotFound catch (e) {
    stderr.writeln(e.toString());
    stderr.writeln(
      'Change it with `amscan init --project`, '
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
    addCommand(InitCommand());
    addCommand(GuiCommand());
    addCommand(ScanCommand());
    addCommand(RemoveCommand());
    addCommand(DisableCommand());
    addCommand(ClearCommand());
    addCommand(UninstallCommand());
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
    argParser.addFlag(
      'accept-all',
      abbr: 'a',
      negatable: false,
      help: 'Answer every prompt with its affirmative and never wait for '
          'input — for unattended runs. Implies --all.',
    );
    argParser.addOption(
      'models',
      help: 'Directory of API model classes — or a single `.dart` file — '
          'relative to the project root. Overrides the remembered default '
          'for this run.',
      valueHelp: 'dir',
    );
  }

  /// Whether prompts should answer themselves.
  bool get acceptAll => argResults!['accept-all'] as bool;

  String get projectRoot => Directory.current.absolute.path;

  static String? get _home =>
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];

  String? _models;

  /// The directory being scanned. Only valid once [resolveModels] has run.
  String get modelsPath => _models!;

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
      throw ModelsDirectoryNotSet(
        initialised: ModelsConfig.hasGlobalConfig(),
      );
    }

    _models = configured.absolute(projectRoot);
  }

  CacheStore get cache => CacheStore(projectRoot);

  void say(String message) => stdout.writeln(message);

  void printHeader(String title) {
    say('');
    say(bold(headingLine(title)));
    say('');
    say(labelled(
      'Project',
      '${accent(p.basename(projectRoot))}  '
          '${dim(homePath(projectRoot, home: _home))}',
    ));
    // Absent on the paths that work from the disabled record rather than by
    // scanning, where naming a models directory would only mislead.
    if (_models != null) {
      say(labelled('Models', shortPath(modelsPath, projectRoot)));
    }
    say('');
  }

  /// Runs a full scan and writes the cache.
  Future<UnusedCache> scanAndCache() async {
    final discovered = await findModels(modelsPath: modelsPath);
    final fields = discovered.fields;

    final classCount = discovered.classes.length;
    say('  ${dim('Found')}  ${fields.length} model '
        'field${fields.length == 1 ? '' : 's'} in $classCount '
        'class${classCount == 1 ? '' : 'es'}');

    // Worth saying out loud: a class without `fromJson`/`toJson` is not one
    // this tool can reason about, and silently ignoring it would read as
    // "nothing unused here".
    if (discovered.skipped.isNotEmpty) {
      final names = discovered.skipped.take(3).join(', ');
      say('  ${dim('Skipped')}  ${discovered.skipped.length} '
          'class${discovered.skipped.length == 1 ? '' : 'es'} with no '
          '`fromJson`/`toJson` ${dim('($names'
          '${discovered.skipped.length > 3 ? ', …' : ''})')}');
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
      say('  ${dim('Dead')}  ${deadClasses.length} '
          'class${deadClasses.length == 1 ? '' : 'es'} dead outright '
          '${dim('(${deadClasses.keys.map((k) => k.split('|').last).join(', ')})')}');
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

    // An empty record is a finished run, not results worth keeping — there is
    // nothing to show, so asking whether to rescan wastes the question.
    if (existing != null && existing.fields.isNotEmpty) {
      say('  Cached results found — scanned ${existing.age}, '
          '${existing.fields.length} potentially unused.');
      say('');

      final flag = argResults!['rescan'] as bool?;
      // An explicit --rescan/--no-rescan wins; otherwise -a says yes.
      final rescan = flag ??
          (acceptAll ||
              !canPrompt ||
              selectSingle('  Rescan the project?', [
                    'Yes — rescan now (replaces the cached report)',
                    'No — keep the existing report',
                  ]) ==
                  0);

      if (!rescan) {
        say('  Keeping the existing report:');
        say('  ${cache.reportPath}');
        say('');
        // Declining a rescan still means "show me the results".
        if (shouldOpen && openInEditor(cache.reportPath) == null) {
          say('  Could not open an editor automatically — open the path above.');
          say('');
        }
        return 0;
      }
    }

    final result = await scanAndCache();

    if (result.fields.isEmpty) {
      say('  No unused model fields found.');
      say('');
      return 0;
    }

    final classes = result.fields.map((f) => f.className).toSet().length;
    say('');
    say('  ${result.fields.isEmpty ? good('✓') : warnish('!')}  '
        '${bold('${result.fields.length} potentially unused '
            'field${result.fields.length == 1 ? '' : 's'}')} '
        'across $classes class${classes == 1 ? '' : 'es'}');
    say('');
    say(bold(headingLine('Report')));
    say('');
    say('  ${accent(shortPath(cache.reportPath, projectRoot))}');
    say('');

    if (shouldOpen && openInEditor(cache.reportPath) == null) {
      say(dim('  Could not open an editor automatically — '
          'open the path above.'));
      say('');
    }

    say('  ${dim('Next')}  Tick what you want, then run '
        '${accent('amscan remove')} or ${accent('amscan disable')}.');
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
      say('  Cached results found — scanned ${result.age}, '
          '${result.fields.length} potentially unused.');
      say('');
      final rescan = acceptAll ||
          !canPrompt ||
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
      say('  No unused model fields recorded. Nothing to do.');
      say('');
      return 0;
    }

    final selection = _resolveSelection(result);
    if (selection == null) {
      say('  Nothing selected. Exiting without changes.');
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
      say('  Skipped ${summary.skipped.length}: ${summary.skipped.join(', ')}');
    }

    if (summary.modifiedFiles.isNotEmpty) {
      // Keep the report alive for whatever is still outstanding, rather than
      // throwing away ticks for fields that were never touched.
      final remaining = result.fields
          .where((f) => !summary.handledKeys
              .contains('${f.filePath}|${f.className}|${f.fieldName}'))
          .toList();

      // Written even when empty. Keeping the header — when this was scanned,
      // and where — is what lets `disable --undo` hand fields back to this
      // record instead of losing them, and leaves `clear` as the only thing
      // that removes it.
      cache.write(UnusedCache(
        scannedAt: result.scannedAt,
        projectRoot: result.projectRoot,
        modelsPath: result.modelsPath,
        totalFieldsScanned: result.totalFieldsScanned,
        fields: remaining,
        deadClasses: result.deadClasses,
      ));

      if (remaining.isEmpty) {
        say('');
        say(mode == EditMode.delete
            ? 'All recorded fields handled — nothing left to act on.'
            : 'All recorded fields disabled — '
                'undo with `amscan disable --undo`.');
      } else {
        say('');
        say('${remaining.length} field${remaining.length == 1 ? '' : 's'} '
            'still listed in the report.');
      }

      if (summary.disabled.isNotEmpty) {
        DisabledStore(projectRoot).add(summary.disabled);
        say('  Recorded in ${DisabledStore(projectRoot).reportPath}');
        say('  Undo with `amscan disable --undo`, '
            'or delete for good with `amscan disable --remove`.');
      }

      tidyRecords(cache, DisabledStore(projectRoot));

      say('  Review with `git diff`.');
    }

    say('');
    return 0;
  }

  /// Reads the ticks from the report, falling back to a prompt when nothing
  /// is selected. Returns null when the user declines.
  Selection? _resolveSelection(UnusedCache result) {
    // --accept-all implies --all: the affirmative answer to "nothing is
    // ticked, act on everything?" is exactly what --all means.
    if (argResults!['all'] as bool || acceptAll) {
      return const Selection(all: true);
    }

    final selection = cache.readSelection();
    if (selection.isNotEmpty) {
      say('  Using ${selection.markedCount} selection'
          '${selection.markedCount == 1 ? '' : 's'} from the report.');
      say('');
      return selection;
    }

    final count = result.fields.length;
    say('  Nothing is ticked in the report:');
    say('  ${cache.reportPath}');
    say('');

    if (!canPrompt) {
      stderr.writeln(
        'Nothing selected and no terminal to ask on. '
        'Pass --all, or -a to answer every prompt.',
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
    // --accept-all implies --all: the affirmative answer to "nothing is
    // ticked, act on everything?" is exactly what --all means.
    if (argResults!['all'] as bool || acceptAll) {
      return const Selection(all: true);
    }

    final selection = store.readSelection();
    if (selection.isNotEmpty) {
      say('  Using ${selection.markedCount} selection'
          '${selection.markedCount == 1 ? '' : 's'} from the record.');
      say('');
      return selection;
    }

    say('  Nothing is ticked in the record:');
    say('  ${store.reportPath}');
    say('');

    if (!canPrompt) {
      stderr.writeln(
        'Nothing selected and no terminal to ask on. '
        'Pass --all, or -a to answer every prompt.',
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
      say('  Nothing is disabled.');
      say('');
      return 0;
    }

    // Same selection contract as the unused report: ticks win, and with
    // nothing ticked we ask before touching everything.
    final selection = _selectDisabled(store, all, restore: restore);
    if (selection == null) {
      say('  Nothing selected. Exiting without changes.');
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
      say('  Nothing selected matches the record.');
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
      say('  Nothing changed.');
      say('');
      return 0;
    }

    // Same safety net as the other mutating paths.
    final broke = await analysisErrors(projectRoot, changed);
    if (broke == null || broke.isNotEmpty) {
      for (final entry in originals.entries) {
        await File(entry.key).writeAsString(entry.value);
      }
      say('  Reverted: the change did not verify with `dart analyze`.');
      for (final line in (broke ?? const <String>[]).take(5)) {
        say('  $line');
      }
      say('');
      return 1;
    }

    // Only once nothing is commented out anywhere: formatting around a
    // surviving comment can remove a separator that its undo still needs.
    if ((argResults!['format'] as bool) && store.isEmpty) {
      await Process.run(
        'dart',
        ['format', ...changed],
        workingDirectory: projectRoot,
        runInShell: true,
      );
    }

    store.remove(done);

    // Undo puts the code back, so the fields are unused again — hand them to
    // the unused record rather than dropping them. Without this the cycle
    // loses information: the code is byte-identical to what was scanned, but
    // nothing remembers that these fields were found, so the next command has
    // to rescan the whole project to rediscover what it already knew.
    //
    // Only for `--undo`. `--remove` deletes the code for good, and a field
    // that no longer exists does not belong in a list of unused ones.
    if (restore && done.isNotEmpty) {
      final restored = all.where((f) => done.contains(f.key)).toList();
      final existing = cache.read();

      if (existing == null) {
        say('');
        say('  Restored, but there is no scan to return them to — '
            'run `amscan scan` to list them again.');
      } else {
        final known = {
          for (final f in existing.fields)
            '${f.filePath}|${f.className}|${f.fieldName}',
        };
        final added = [
          for (final f in restored)
            if (!known.contains('${f.filePath}|${f.className}|${f.fieldName}') &&
                f.fieldName != _wholeClassField)
              CachedField(
                className: f.className,
                fieldName: f.fieldName,
                filePath: f.filePath,
                line: f.line,
              ),
        ];

        if (added.isNotEmpty) {
          cache.write(UnusedCache(
            scannedAt: existing.scannedAt,
            projectRoot: existing.projectRoot,
            modelsPath: existing.modelsPath,
            totalFieldsScanned: existing.totalFieldsScanned,
            fields: [...existing.fields, ...added],
            deadClasses: existing.deadClasses,
          ));
          say('${added.length} field${added.length == 1 ? '' : 's'} '
              'back in the report — they are unused again.');
        }
      }
    }

    say('${restore ? 'Re-enabled' : 'Removed'} ${done.length} '
        'field${done.length == 1 ? '' : 's'} '
        'in ${changed.length} file${changed.length == 1 ? '' : 's'}.');
    if (store.isEmpty) {
      say('  Nothing is disabled any more.');
    }

    tidyRecords(cache, store);
    say('');
    return 0;
  }
}

/// Deletes both records once neither holds anything.
///
/// A record has to outlive its contents while the *other* one still has some:
/// `disable` empties the unused report, and `--undo` needs its header — the
/// scan time and models path — to hand the fields back. Once both are empty
/// nothing is outstanding, so there is nothing left to preserve.
void tidyRecords(CacheStore cache, DisabledStore store) {
  final unused = cache.read();
  if ((unused == null || unused.fields.isEmpty) && store.isEmpty) {
    cache.delete();
    store.delete();
  }
}

/// Pseudo field name a whole-class disabled record carries; it names no real
/// field, so it never belongs in the unused report.
const String _wholeClassField = '(whole class)';

/// `amscan gui`, `amscan gui install`, `amscan gui uninstall`
///
/// Pub runs nothing on `activate` or `deactivate` — a package may never
/// execute its own code as a side effect of being installed — so the editor
/// cannot ride along with either. These commands are how it is managed, and
/// `init` is where it is offered; this manages it afterwards.
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

/// `amscan init [<dir>]`
///
/// The one-off setup step. Pub runs nothing on `activate` — verified, and by
/// design — so there is no way to trigger this at install time; it has to be
/// the first thing you run.
class InitCommand extends Command<int> {
  InitCommand() {
    argParser
      ..addFlag(
        'project',
        negatable: false,
        help: 'Set the models directory for this project only. A project '
            'setting wins over the machine-wide one.',
      )
      ..addFlag(
        'accept-all',
        abbr: 'a',
        negatable: false,
        help: 'Never wait for input. Anything not given as a flag is left '
            'unset rather than guessed.',
      )
      ..addOption(
        'editor',
        help: 'Editor command that manages the report editor and opens the '
            'report. Machine-wide.',
        valueHelp: 'command',
      )
      ..addOption(
        'gui',
        help: 'Whether to install the VS Code report editor. Machine-wide.',
        allowed: ['yes', 'no'],
      );
  }

  @override
  String get name => 'init';

  @override
  String get description =>
      'Set up api_model_scanner — run this once after installing.';

  @override
  String get invocation => 'api_model_scanner init [<dir>]';

  String get _root => Directory.current.absolute.path;

  bool get _acceptAll => argResults!['accept-all'] as bool;
  bool get _forProject => argResults!['project'] as bool;

  void _say(String message) => stdout.writeln(message);

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.length > 1) {
      stderr.writeln('Usage: amscan init [<dir>]');
      return 64;
    }

    final projectRoot = _root;

    if (_forProject && !looksLikeDartProject(projectRoot)) {
      stderr.writeln('No pubspec.yaml here, so this is not a Dart project: '
          '$projectRoot');
      stderr.writeln('');
      stderr.writeln('Run `amscan init --project` from a project root, or '
          '`amscan init` to set a default for every project.');
      return 66;
    }

    final givenDir = rest.isEmpty ? null : rest.single.trim();
    final givenEditor = argResults!.wasParsed('editor')
        ? (argResults!['editor'] as String).trim()
        : null;
    final givenGui = argResults!.wasParsed('gui')
        ? argResults!['gui'] == 'yes'
        : null;

    final wasGivenSomething =
        givenDir != null || givenEditor != null || givenGui != null;

    // A setter must not block, so anything given on the command line is
    // applied as-is and nothing is asked.
    if (wasGivenSomething) {
      return _applyDirectly(
        projectRoot: projectRoot,
        models: givenDir,
        editor: givenEditor,
        gui: givenGui,
      );
    }

    final existing = _describeExisting(projectRoot);

    if (_acceptAll) {
      // Nothing was given and nothing may be asked. Report, and for a
      // machine-wide run record that init has been through.
      if (existing.isNotEmpty) {
        existing.forEach(_say);
        return 0;
      }
      if (_forProject) {
        stderr.writeln('Nothing to set: pass a directory, as '
            '`amscan init --project <dir>`.');
        return 64;
      }
      applyInit(const InitAnswers(), projectRoot: projectRoot);
      _say('Recorded. Nothing was asked, so no setting was changed.');
      return 0;
    }

    if (existing.isNotEmpty) {
      existing.forEach(_say);
      _say('');
      if (!canPrompt) {
        _say('Run `amscan init` from a terminal to change any of this.');
        return 0;
      }
      final change = selectSingle('  Change any of this?', [
        'No — leave it as it is',
        'Yes — go through the questions again',
      ]);
      if (change != 1) {
        return 0;
      }
    }

    if (!canPrompt) {
      stderr.writeln('There is no terminal here to ask on.');
      stderr.writeln('');
      stderr.writeln('Pass the answers instead:');
      stderr.writeln('  amscan init <dir> [--editor=<command>] [--gui=yes|no]');
      return 78;
    }

    return _wizard(projectRoot);
  }

  /// Applies command-line answers without asking anything.
  Future<int> _applyDirectly({
    required String projectRoot,
    String? models,
    String? editor,
    bool? gui,
  }) async {
    String? relative;

    if (models != null) {
      if (models.isEmpty) {
        stderr.writeln('Usage: amscan init [<dir>]');
        return 64;
      }

      relative = p.normalize(
        p.isAbsolute(models) ? p.relative(models, from: projectRoot) : models,
      );

      final checked =
          await checkModelsPath(projectRoot: projectRoot, relative: relative);

      if (checked.verdict == ModelsPathVerdict.outsideProject) {
        stderr.writeln('That directory is outside the project: $models');
        return 64;
      }

      // Anything else is only a warning. A machine-wide default names a
      // directory that need not exist *here*, and a setter that refused
      // would be unusable from a script.
      final note = _warningFor(checked.verdict, relative);
      if (note != null) {
        stderr.writeln('Warning: $note');
      }
    }

    if (gui == true) {
      _install(editor: editor);
    }

    final written = applyInit(
      InitAnswers(
        models: relative,
        gui: gui,
        editor: editor,
        forProject: _forProject,
      ),
      projectRoot: projectRoot,
    );

    _say('  ${good('✓')} Saved to ${homePath(written)}');
    _say('');
    _describeExisting(projectRoot).forEach(_say);
    return 0;
  }

  String? _warningFor(ModelsPathVerdict verdict, String relative) =>
      switch (verdict) {
        ModelsPathVerdict.ok => null,
        ModelsPathVerdict.outsideProject => null,
        ModelsPathVerdict.missing =>
          '$relative does not exist in this project.',
        ModelsPathVerdict.notADartFile => '$relative is not Dart source.',
        ModelsPathVerdict.noModelClasses =>
          '$relative declares no `fromJson`/`toJson` classes.',
      };

  /// The interactive path.
  Future<int> _wizard(String projectRoot) async {
    _say('');
    _say(bold(headingLine('Setting up api_model_scanner')));
    _say('');

    final inProject = looksLikeDartProject(projectRoot);
    String? models;

    if (inProject) {
      models = await _askForModels(projectRoot);
    } else if (!_forProject) {
      _say('No pubspec.yaml here, so this is not a project — asking about '
          'the editor only.');
      _say('');
    }

    bool? gui;
    String? editor;

    if (!_forProject) {
      editor = _askForEditor();
      gui = _askForGui(editor);
    }

    // A project run with nothing to say writes nothing, so there is no file
    // to point at.
    if (_forProject && models == null) {
      _say('');
      _say('Nothing changed.');
      _say('');
      return 0;
    }

    final written = applyInit(
      InitAnswers(
        models: models,
        gui: gui,
        editor: editor,
        forProject: _forProject,
      ),
      projectRoot: projectRoot,
    );

    _say('');
    _say('  ${good('✓')} Saved to ${homePath(written)}');
    _say('');
    _say(models == null && ModelsConfig.resolve(projectRoot) == null
        ? 'Set a models directory with `amscan init --project` in a project, '
            'then run `amscan scan`.'
        : 'Run `amscan scan` to start.');
    _say('');
    return 0;
  }

  /// Asks where the models live, and keeps asking while the answer cannot
  /// be used.
  ///
  /// Unlike the non-interactive setter this re-asks, since there is somebody
  /// there to correct the typo. Blank keeps whatever is already set, or skips
  /// when nothing is.
  Future<String?> _askForModels(String projectRoot) async {
    final current = _forProject
        ? ModelsConfig.readProject(projectRoot)
        : ModelsConfig.readGlobal();

    _say('');
    _say(_forProject
        ? "Where do this project's API model classes live?"
        : 'Where do your API model classes usually live?');
    _say('');
    _say('  A directory, or one `.dart` file, relative to the project root.');
    _say('  For example: lib/server/response');
    _say(current == null
        ? '  Leave it blank to set it per project instead.'
        : '  Leave it blank to keep $current.');
    _say('');

    while (true) {
      final typed = promptLine('  Path:');
      if (typed == null) {
        return current;
      }

      final relative = p.normalize(
        p.isAbsolute(typed) ? p.relative(typed, from: projectRoot) : typed,
      );

      final checked =
          await checkModelsPath(projectRoot: projectRoot, relative: relative);

      switch (checked.verdict) {
        case ModelsPathVerdict.ok:
          _say('  ${checked.classCount} model '
              'class${checked.classCount == 1 ? '' : 'es'} in $relative.');
          return relative;

        // Worth saying, but not worth refusing: a directory can be empty
        // today and full tomorrow.
        case ModelsPathVerdict.noModelClasses:
          _say('  $relative declares no `fromJson`/`toJson` classes — '
              'using it anyway.');
          return relative;

        case ModelsPathVerdict.outsideProject:
          _say('  That is outside the project; the setting is stored '
              'relative to it.');
        case ModelsPathVerdict.missing:
          _say('  Nothing at $relative.');
        case ModelsPathVerdict.notADartFile:
          _say('  $relative is not Dart source.');
      }
    }
  }

  /// Settles which editor command to drive.
  ///
  /// One installed editor is not a choice, so it is taken and named rather
  /// than put to a vote. Several is a real choice, and none still is — the
  /// setting can be recorded now and the editor installed later.
  String _askForEditor() {
    final detected = detectEditors();

    if (detected.length == 1) {
      _say('');
      _say(labelled('Editor', '${detected.single} ${dim('(Auto detected)')}'));
      return detected.single;
    }

    final options = editorChoices(detected);

    _say('');
    if (detected.isEmpty) {
      _say('No editor command is on PATH, so none of these can be checked.');
      _say('In VS Code: Command Palette → '
          '"Shell Command: Install \'code\' command in PATH".');
      _say('');
    }

    final labels = [
      for (final command in options)
        detected.contains(command) ? '$command (Auto detected)' : command,
    ];

    final current = ModelsConfig.readEditor();
    final at = options.indexOf(current ?? '');

    final chosen = selectSingle(
      '  Which editor should amscan use?',
      labels,
      defaultIndex: at < 0 ? 0 : at,
    );

    return options[chosen];
  }

  /// Offers the report editor, and installs it on a yes.
  bool? _askForGui(String editor) {
    if (guiInstalled(editor: editor)) {
      _say('The report editor is already installed.');
      return true;
    }

    _say('');
    _say('There is an editor extension for the report: a real table with '
        'checkbox cells, instead of a Markdown list.');
    _say('');

    // No comes first so it is what `selectSingle` returns on q or Ctrl-C.
    // Silence is a decline: an editor extension should never arrive
    // uninvited.
    final choice = selectSingle('  Install it?', [
      'No — the Markdown report is fine',
      'Yes — install it now',
    ]);

    if (choice != 1) {
      _say('Skipped. Run `amscan gui install` if you change your mind.');
      return false;
    }

    return _install(editor: editor);
  }

  bool _install({String? editor}) {
    final result = installGui(editor: editor);
    if (result.ok) {
      _say('Installed $extensionId. Reload the editor window to use it.');
    } else {
      _say('Could not install it; the Markdown report still works. '
          'Try `amscan gui install` for the details.');
    }
    return result.ok;
  }

  /// The settings already in force, as lines. Empty when there are none.
  List<String> _describeExisting(String projectRoot) {
    final resolved = ModelsConfig.resolve(projectRoot);
    final editor = ModelsConfig.readEditor();
    final gui = ModelsConfig.readGuiPreference();

    if (resolved == null && editor == null && gui == null) {
      return ModelsConfig.hasGlobalConfig()
          ? const ['Set up, but nothing is configured yet.']
          : const [];
    }

    return [
      bold(headingLine('Current settings')),
      '',
      if (resolved != null)
        labelled(
          'Models',
          '${accent(resolved.relative)}  ${dim('(${switch (resolved.source) {
            ModelsSource.project => 'this project',
            ModelsSource.global => 'every project',
            ModelsSource.flag => 'this run',
          }})')}',
          width: 14,
        )
      else
        labelled('Models', dim('not set'), width: 14),
      labelled('Editor', editor == null ? dim('not set') : accent(editor),
          width: 14),
      labelled(
        'Report editor',
        switch (gui) {
          true => good('wanted'),
          false => dim('declined'),
          null => dim('not answered'),
        },
        width: 14,
      ),
      '',
      '  ${dim(homePath(ModelsConfig.globalPath()))}',
      if (ModelsConfig.readProject(projectRoot) != null)
        '  ${dim(shortPath(ModelsConfig.projectPath(projectRoot), projectRoot))}',
    ];
  }
}

/// `amscan uninstall`
///
/// The opposite of `init`: takes the editor extension, the settings and the
/// tool itself back off the machine.
class UninstallCommand extends Command<int> {
  UninstallCommand() {
    argParser
      ..addFlag(
        'yes',
        abbr: 'y',
        negatable: false,
        help: 'Do not ask for confirmation.',
      )
      ..addFlag(
        'force',
        negatable: false,
        help: 'Go ahead even when code is still commented out. That code '
            'can no longer be restored afterwards.',
      )
      ..addFlag(
        'keep-tool',
        negatable: false,
        help: 'Remove the editor and the settings, but leave the command '
            'installed.',
      );
  }

  @override
  String get name => 'uninstall';

  @override
  String get description =>
      'Remove the editor, every setting, and the tool itself.';

  void _say(String message) => stdout.writeln(message);

  @override
  Future<int> run() async {
    final projectRoot = Directory.current.absolute.path;
    final plan = planUninstall(projectRoot: projectRoot);
    final keepTool = argResults!['keep-tool'] as bool;
    final editor = resolvedEditor();
    final hasExtension = guiInstalled(editor: editor);

    _say('');
    _say(bold(headingLine('Uninstall')));
    _say('');

    // The one way this is not reversible. `disable` keeps the original source
    // in the record, not in the commented-out file, so deleting the record
    // strands that code — and the commented code looks fine until somebody
    // tries to undo it.
    if (plan.wouldStrandDisabledCode && !(argResults!['force'] as bool)) {
      _say('  ${bad('${plan.disabledFieldCount} field'
          '${plan.disabledFieldCount == 1 ? '' : 's'} '
          'in this project '
          '${plan.disabledFieldCount == 1 ? 'is' : 'are'} still commented '
          'out.')}');
      _say('');
      _say('  Uninstalling deletes the record that holds their original '
          'source,');
      _say('  so `disable --undo` could never put them back.');
      _say('');
      _say('  ${dim('First')}  ${accent('amscan disable --undo')}   '
          '${dim('put them back')}');
      _say('  ${dim('   or')}  ${accent('amscan disable --remove')} '
          '${dim('delete them for good')}');
      _say('');
      _say('  ${dim('Or pass --force to uninstall anyway.')}');
      _say('');
      return 78;
    }

    final lines = <String>[
      if (hasExtension) '$extensionId ${dim('($editor)')}',
      if (plan.projectDirectory != null)
        '${shortPath(plan.projectDirectory!, projectRoot)} '
            '${dim('settings and cached reports')}',
      if (plan.globalConfigDirectory != null)
        '${homePath(plan.globalConfigDirectory!)} ${dim('settings')}',
      if (!keepTool) 'the `amscan` command itself ${dim('(pub deactivate)')}',
    ];

    if (lines.isEmpty) {
      _say('  Nothing to remove — already clean.');
      _say('');
      return 0;
    }

    _say('  This will remove:');
    _say('');
    for (final line in lines) {
      _say('    ${bad('-')} $line');
    }
    _say('');
    _say('  ${dim('Your source code is not touched.')}');
    _say('');

    if (!(argResults!['yes'] as bool)) {
      if (!canPrompt) {
        _say('  Re-run with ${accent('-y')} to confirm.');
        _say('');
        return 78;
      }
      // No first, so cancelling keeps everything.
      final choice = selectSingle('  Go ahead?', [
        'No — keep everything',
        'Yes — remove it all',
      ]);
      if (choice != 1) {
        _say('  ${dim('Nothing was removed.')}');
        _say('');
        return 0;
      }
    }

    if (hasExtension) {
      _say(uninstallGui(editor: editor)
          ? '  ${good('✓')} Removed $extensionId'
          : '  ${warnish('!')} Could not remove $extensionId — '
              'try `$editor --uninstall-extension $extensionId`');
    }

    for (final directory in applyUninstall(plan)) {
      _say('  ${good('✓')} Removed ${homePath(shortPath(directory, projectRoot))}');
    }

    if (keepTool) {
      _say('');
      _say('  ${dim('The command is still installed.')}');
      _say('');
      return 0;
    }

    // Last: this removes the snapshot currently running.
    final deactivated = deactivateSelf();
    _say(deactivated.ok
        ? '  ${good('✓')} Deactivated api_model_scanner'
        : '  ${warnish('!')} Could not deactivate it '
            '${dim('(not globally activated?)')}');
    if (!deactivated.ok && deactivated.detail.isNotEmpty) {
      _say('    ${dim(deactivated.detail.split('\n').first)}');
    }

    _say('');
    _say('  ${dim('Gone. Reinstall with `dart pub global activate` '
        'and `amscan init`.')}');
    _say('');
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
