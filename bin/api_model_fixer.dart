import 'dart:io';

import 'package:api_model_scanner/src/fix_runner.dart';
import 'package:args/args.dart';
import 'package:path/path.dart' as p;

// Reuse the scanner's discovery + LSP building blocks without modifying them.
import 'api_model_scanner.dart' as scanner;

/// Standalone CLI that finds unused API-model fields (using the exact same
/// discovery + semantic-reference logic as `api_model_scanner.dart`) and then
/// removes them with AST-aware source edits.
///
/// The scan half and the fix half are kept apart on purpose:
///   * scanning primitives live in `bin/api_model_scanner.dart`,
///   * the AST rewriting lives in `lib/src/model_field_fixer.dart`,
///   * the apply/dry-run orchestration lives in `lib/src/fix_runner.dart`,
///   * this file only wires them together.
///
/// Usage:
///   dart run bin/api_model_fixer.dart            # report unused (no writes)
///   dart run bin/api_model_fixer.dart --dry-run  # show the exact edits
///   dart run bin/api_model_fixer.dart --fix      # apply edits + dart format
Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption(
      'models',
      defaultsTo: 'lib/server/response',
      help: 'Directory containing API models.',
    )
    ..addFlag(
      'fix',
      defaultsTo: false,
      negatable: false,
      help: 'Remove unused fields from the source files.',
    )
    ..addFlag(
      'dry-run',
      defaultsTo: false,
      negatable: false,
      help: 'Show what --fix would change without writing anything.',
    )
    ..addFlag(
      'format',
      defaultsTo: true,
      help: 'Run `dart format` on modified files after --fix.',
    )
    ..addFlag(
      'force',
      defaultsTo: false,
      negatable: false,
      help: 'Apply --fix even if the git working tree is dirty.',
    )
    ..addFlag('help', abbr: 'h', defaultsTo: false, negatable: false);

  final ArgResults args;
  try {
    args = parser.parse(arguments);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    stderr.writeln(parser.usage);
    exitCode = 64;
    return;
  }

  if (args['help'] as bool) {
    print('API Model Field Fixer\n');
    print(parser.usage);
    return;
  }

  final apply = args['fix'] as bool;
  final dryRun = args['dry-run'] as bool;
  final runFormat = args['format'] as bool;
  final force = args['force'] as bool;

  final projectRoot = Directory.current.absolute.path;
  final modelsPath = p.normalize(p.join(projectRoot, args['models'] as String));

  print('');
  print('API Model Field Fixer');
  print('=====================');
  print('');
  print('Project: $projectRoot');
  print('Models:  $modelsPath');
  print('Mode:    ${apply ? 'FIX' : (dryRun ? 'DRY-RUN' : 'REPORT')}');
  print('');

  if (apply && !force) {
    final dirty = await gitWorkingTreeDirty(projectRoot);
    if (dirty == true) {
      stderr.writeln(
        'Refusing to --fix: git working tree is not clean.\n'
        'Commit or stash your changes first, or pass --force.',
      );
      exitCode = 1;
      return;
    }
  }

  // 1. Discover model fields (reused from the scanner).
  final fields = await scanner.findModelFields(
    projectRoot: projectRoot,
    modelsPath: modelsPath,
  );
  print('Found ${fields.length} model fields.');
  print('');

  // 2. Find unused fields via the language server (reused from the scanner).
  final unused = await _findUnusedFields(projectRoot, fields);

  if (unused.isEmpty) {
    print('\nNo unused model fields found. Nothing to fix.');
    return;
  }

  print('\nPotentially unused fields: ${unused.length}\n');

  if (!apply && !dryRun) {
    _printReport(unused, projectRoot);
    print('Re-run with --dry-run to preview edits, or --fix to apply them.');
    return;
  }

  // 3. Apply AST-aware removals via the shared runner.
  await applyFixes(
    projectRoot: projectRoot,
    unused: unused
        .map((f) => UnusedField(
              filePath: f.filePath,
              className: f.className,
              fieldName: f.fieldName,
            ))
        .toList(),
    apply: apply,
    dryRun: dryRun,
    runFormat: runFormat,
  );
}

/// Runs the same reference-based unused detection the scanner performs.
Future<List<scanner.ModelField>> _findUnusedFields(
  String projectRoot,
  List<scanner.ModelField> fields,
) async {
  final server = scanner.DartLanguageServer();
  final unused = <scanner.ModelField>[];

  try {
    print('Starting Dart language server...');
    await server.start(projectRoot);
    print('Dart language server ready.');

    for (var i = 0; i < fields.length; i++) {
      final field = fields[i];
      stdout.write(
        '\rScanning ${i + 1}/${fields.length}: '
        '${field.className}.${field.fieldName}                    ',
      );

      try {
        final references = await server.findReferences(
          filePath: field.filePath,
          line: field.line,
          character: field.column,
        );

        final external = references
            .where((r) => !scanner.isInsideModelFile(r, field))
            .toList();

        if (external.isEmpty) {
          unused.add(field);
        }
      } catch (e) {
        stderr.writeln(
          '\nFailed to inspect ${field.className}.${field.fieldName}: $e',
        );
      }
    }
  } finally {
    await server.shutdown();
  }

  return unused;
}

void _printReport(List<scanner.ModelField> unused, String projectRoot) {
  final byFile = <String, List<scanner.ModelField>>{};
  for (final field in unused) {
    byFile.putIfAbsent(field.filePath, () => []).add(field);
  }

  for (final entry in byFile.entries) {
    final rel = p.relative(entry.key, from: projectRoot);
    final byClass = <String, List<scanner.ModelField>>{};
    for (final field in entry.value) {
      byClass.putIfAbsent(field.className, () => []).add(field);
    }
    for (final classEntry in byClass.entries) {
      print('${classEntry.key}  ($rel)');
      for (final field in classEntry.value) {
        print('  ✗ ${field.fieldName}  (line ${field.line + 1})');
      }
      print('');
    }
  }
}
