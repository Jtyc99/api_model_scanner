import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../model.dart';
import 'report.dart';
import 'selection.dart';

/// One potentially unused field, as recorded in the cache.
class CachedField {
  final String className;
  final String fieldName;

  /// Absolute path to the file declaring the field.
  final String filePath;

  /// One-based declaration line.
  final int line;

  const CachedField({
    required this.className,
    required this.fieldName,
    required this.filePath,
    required this.line,
  });

  factory CachedField.fromModelField(ModelField field) => CachedField(
        className: field.className,
        fieldName: field.fieldName,
        filePath: field.filePath,
        line: field.line + 1,
      );

  Map<String, dynamic> toJson() => {
        'class': className,
        'field': fieldName,
        'file': filePath,
        'line': line,
      };

  factory CachedField.fromJson(Map<String, dynamic> json) => CachedField(
        className: json['class'] as String,
        fieldName: json['field'] as String,
        filePath: json['file'] as String,
        line: json['line'] as int,
      );
}

/// The result of a scan, persisted so later commands need not rescan.
class UnusedCache {
  final DateTime scannedAt;
  final String projectRoot;
  final String modelsPath;
  final int totalFieldsScanned;
  final List<CachedField> fields;

  /// Classes that are dead outright: every field unused, and every remaining
  /// reference to the type lives inside code that is itself being removed.
  /// Dead class -> the `Class.field` keys its verdict depends on.
  final Map<String, Set<String>> deadClasses;

  const UnusedCache({
    required this.scannedAt,
    required this.projectRoot,
    required this.modelsPath,
    required this.totalFieldsScanned,
    required this.fields,
    this.deadClasses = const {},
  });

  Map<String, dynamic> toJson() => {
        'scannedAt': scannedAt.toIso8601String(),
        'projectRoot': projectRoot,
        'modelsPath': modelsPath,
        'totalFieldsScanned': totalFieldsScanned,
        'fields': fields.map((f) => f.toJson()).toList(),
        'deadClasses': {
          for (final entry in deadClasses.entries)
            entry.key: entry.value.toList(),
        },
      };

  factory UnusedCache.fromJson(Map<String, dynamic> json) => UnusedCache(
        scannedAt: DateTime.parse(json['scannedAt'] as String),
        projectRoot: json['projectRoot'] as String,
        modelsPath: json['modelsPath'] as String,
        totalFieldsScanned: json['totalFieldsScanned'] as int? ?? 0,
        fields: (json['fields'] as List<dynamic>)
            .map((e) => CachedField.fromJson(e as Map<String, dynamic>))
            .toList(),
        // A list is the old shape, which recorded no conditions. Those
        // verdicts cannot be re-checked against a selection, so they are
        // dropped rather than trusted; the next scan rebuilds them.
        deadClasses: switch (json['deadClasses']) {
          final Map<String, dynamic> map => {
              for (final entry in map.entries)
                entry.key: (entry.value as List<dynamic>).cast<String>().toSet(),
            },
          _ => const <String, Set<String>>{},
        },
      );

  /// Human-readable age, e.g. "4 minutes ago".
  String get age {
    final d = DateTime.now().difference(scannedAt);
    if (d.inSeconds < 60) return '${d.inSeconds}s ago';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }
}

/// Reads and writes the scan cache under `.dart_tool/`, which is already
/// git-ignored in every Dart/Flutter project.
class CacheStore {
  final String projectRoot;

  CacheStore(this.projectRoot);

  String get directory =>
      p.join(projectRoot, '.dart_tool', 'api_model_scanner');

  /// Machine-readable cache consumed by `fix`.
  String get jsonPath => p.join(directory, 'unused_fields.json');

  /// Human-readable report opened in the editor.
  String get reportPath => p.join(directory, 'unused_fields.md');

  bool get exists => File(jsonPath).existsSync();

  UnusedCache? read() {
    final file = File(jsonPath);
    if (!file.existsSync()) {
      return null;
    }
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      return UnusedCache.fromJson(json);
    } catch (_) {
      // A corrupt or outdated cache is treated as absent.
      return null;
    }
  }

  /// Writes both the JSON cache and the Markdown report.
  /// Orders fields by where they are declared.
  ///
  /// A scan already yields declaration order within each file, so sorting by
  /// file and line is what puts a field handed back by `--undo` exactly where
  /// it was rather than at the end. It also makes the written record
  /// deterministic, where it previously followed directory-listing order.
  static UnusedCache _ordered(UnusedCache cache) => UnusedCache(
        scannedAt: cache.scannedAt,
        projectRoot: cache.projectRoot,
        modelsPath: cache.modelsPath,
        totalFieldsScanned: cache.totalFieldsScanned,
        deadClasses: cache.deadClasses,
        fields: cache.fields.toList()
          ..sort((a, b) {
            final byFile = a.filePath.compareTo(b.filePath);
            if (byFile != 0) {
              return byFile;
            }
            final byLine = a.line.compareTo(b.line);
            if (byLine != 0) {
              return byLine;
            }
            // Several variables may share one declaration line.
            return a.fieldName.compareTo(b.fieldName);
          }),
      );

  void write(UnusedCache raw) {
    final cache = _ordered(raw);
    Directory(directory).createSync(recursive: true);
    File(jsonPath).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(cache.toJson()),
    );
    File(reportPath).writeAsStringSync(renderReport(cache));
  }

  void delete() {
    for (final path in [jsonPath, reportPath]) {
      final file = File(path);
      if (file.existsSync()) {
        file.deleteSync();
      }
    }
  }

  /// Files in the cache directory that are settings rather than results, and
  /// so must survive `clear`.
  static const _kept = {'config.json'};

  /// Removes the cached results. Returns the files that were deleted.
  List<String> clearAll() {
    final dir = Directory(directory);
    if (!dir.existsSync()) {
      return const [];
    }

    final removed = <String>[];
    for (final file in dir.listSync(recursive: true).whereType<File>()) {
      if (_kept.contains(p.basename(file.path))) {
        continue;
      }
      file.deleteSync();
      removed.add(file.path);
    }

    // Only tidy the directory away if nothing worth keeping is left in it.
    if (dir.listSync().isEmpty) {
      dir.deleteSync();
    }

    return removed;
  }

  /// Renders the report for [cache] without writing it.
  String renderReport(UnusedCache cache) =>
      ReportRenderer(directory).render(cache);

  /// Reads the report back and returns whatever the user ticked.
  ///
  /// A missing report means nothing is selected, which callers treat as
  /// "ask before acting on everything".
  Selection readSelection() {
    final file = File(reportPath);
    if (!file.existsSync()) {
      return Selection.empty;
    }
    try {
      return parseSelection(file.readAsStringSync(),
          projectRoot: projectRoot);
    } catch (_) {
      return Selection.empty;
    }
  }
}
