import 'dart:async';
import 'dart:io';

import '../lsp/dart_language_server.dart';
import '../model.dart';
import 'dead_classes.dart';
import 'model_discovery.dart';

/// How many times a model field is referenced from outside its own file.
class FieldUsage {
  final ModelField field;

  /// References that live outside the model's declaring file, i.e. real
  /// application usage rather than serialization internals.
  final int externalReferences;

  /// Set when the language server could not resolve this field.
  final String? error;

  /// Public accessors through which this field is reached (e.g. a getter
  /// forwarding a private field). Empty when the field is used directly.
  final List<String> usedVia;

  const FieldUsage({
    required this.field,
    required this.externalReferences,
    this.error,
    this.usedVia = const [],
  });

  /// A field with no external references is *potentially* unused — dynamic
  /// access (`json['x']`) and reflection can hide real usage, so this is a
  /// strong signal rather than a proof.
  bool get isPotentiallyUnused => error == null && externalReferences == 0;
}

/// Field usages plus class references, resolved in one language-server
/// session — starting the server and letting it analyze the workspace is by
/// far the slowest part, so it is not worth paying for twice.
class UsageReport {
  final List<FieldUsage> fields;
  final Map<String, List<ClassReference>> classReferences;

  const UsageReport({required this.fields, required this.classReferences});
}

/// Converts an LSP line/column reference into a character offset.
final _lineCache = <String, List<int>>{};

int _offsetOf(Reference reference) {
  final starts = _lineCache.putIfAbsent(reference.filePath, () {
    final content = File(reference.filePath).readAsStringSync();
    final offsets = <int>[0];
    for (var i = 0; i < content.length; i++) {
      if (content.codeUnitAt(i) == 0x0a) {
        offsets.add(i + 1);
      }
    }
    return offsets;
  });

  if (reference.line < 0 || reference.line >= starts.length) {
    return 0;
  }
  return starts[reference.line] + reference.column;
}

/// Resolves external reference counts for every field in [fields] using the
/// Dart language server rooted at [projectRoot].
///
/// This is the single scanning entry point shared by every CLI command, so
/// `scan` and `fix` can never disagree about what counts as unused.
Future<List<FieldUsage>> analyzeFieldUsage({
  required String projectRoot,
  required List<ModelField> fields,
  void Function(String message)? onStatus,
  void Function(int done, int total, ModelField field)? onProgress,
}) async =>
    (await analyzeUsage(
      projectRoot: projectRoot,
      fields: fields,
      classes: const [],
      onStatus: onStatus,
      onProgress: onProgress,
    ))
        .fields;

/// Resolves field usage and class references together.
Future<UsageReport> analyzeUsage({
  required String projectRoot,
  required List<ModelField> fields,
  required List<ModelClass> classes,
  void Function(String message)? onStatus,
  void Function(int done, int total, ModelField field)? onProgress,
  void Function(int done, int total, ModelClass model)? onClassProgress,
}) async {
  final server = DartLanguageServer();
  final usages = <FieldUsage>[];
  final classReferences = <String, List<ClassReference>>{};

  try {
    onStatus?.call('Starting Dart language server...');
    await server.start(projectRoot);
    onStatus?.call('Dart language server ready.');

    for (var i = 0; i < fields.length; i++) {
      final field = fields[i];

      onProgress?.call(i + 1, fields.length, field);

      // The field's own references, plus those of every public member that
      // exposes it. A privately-stored field reached through a getter has no
      // external references of its own, but is very much in use.
      Future<FieldUsage> inspect() async {
        var external = 0;
        var via = <String>[];

        final direct = await server.findReferences(
          filePath: field.filePath,
          line: field.line,
          character: field.column,
        );
        external += direct.where((r) => !isInsideModelFile(r, field)).length;

        for (final accessor in field.accessors) {
          final refs = await server.findReferences(
            filePath: field.filePath,
            line: accessor.line,
            character: accessor.column,
          );
          final count = refs.where((r) => !isInsideModelFile(r, field)).length;
          if (count > 0) {
            external += count;
            via.add(accessor.name);
          }
        }

        return FieldUsage(
          field: field,
          externalReferences: external,
          usedVia: via,
        );
      }

      try {
        try {
          usages.add(await inspect());
        } on TimeoutException {
          // The first request also pays for the server indexing the project,
          // which on a large one can outlast the timeout. Indexing is done by
          // now, so one retry almost always lands — and a field lost here is
          // one that silently never reaches the report.
          onStatus?.call(
            'Timed out on ${field.className}.${field.fieldName} — retrying',
          );
          usages.add(await inspect());
        }
      } catch (e) {
        usages.add(
          FieldUsage(field: field, externalReferences: 0, error: '$e'),
        );
        onStatus?.call(
          'Failed to inspect ${field.className}.${field.fieldName}: $e',
        );
      }
    }
    for (var i = 0; i < classes.length; i++) {
      final model = classes[i];
      onClassProgress?.call(i + 1, classes.length, model);

      try {
        final references = await server.findReferences(
          filePath: model.filePath,
          line: model.line,
          character: model.column,
        );
        classReferences[model.className] = [
          for (final reference in references)
            ClassReference(
              filePath: reference.filePath,
              offset: _offsetOf(reference),
            ),
        ];
      } catch (e) {
        onStatus?.call('Failed to inspect class ${model.className}: $e');
        classReferences[model.className] = const [];
      }
    }
  } finally {
    await server.shutdown();
  }

  return UsageReport(fields: usages, classReferences: classReferences);
}
