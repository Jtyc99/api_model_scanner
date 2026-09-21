import 'dart:io';

import 'package:path/path.dart' as p;

import '../model_field_fixer.dart';
import 'unused_cache.dart';

/// Renders the human-facing report.
///
/// The report uses GFM task lists rather than a Markdown table: task-list
/// checkboxes only render (and only become clickable) inside list items, never
/// inside table cells. Columns are kept legible by padding labels inside code
/// spans, which stay monospaced when the Markdown is previewed.
///
/// Nothing is hidden in the file. Selection identity is derived from the
/// document's structure — the `##` heading names the class, an unindented task
/// item names a field, and indented items are its parts in order — so the
/// rendered report carries no stray markers.
class ReportRenderer {
  /// Directory the report lives in.
  final String directory;

  ReportRenderer(this.directory);

  String render(UnusedCache cache) {
    final buffer = StringBuffer();

    buffer.writeln('# Unused API model fields');
    buffer.writeln();

    if (cache.fields.isEmpty) {
      buffer.writeln('No unused model fields found. ✅');
      buffer.writeln();
      buffer.writeln('_Scanned ${_formatTime(cache.scannedAt)} · '
          '${cache.totalFieldsScanned} fields checked._');
      buffer.writeln();
      return buffer.toString();
    }

    final classCount = cache.fields.map((f) => f.className).toSet().length;

    buffer.writeln('**${cache.fields.length} fields** · '
        '**$classCount ${classCount == 1 ? 'class' : 'classes'}** · '
        'scanned ${_formatTime(cache.scannedAt)} · '
        '${cache.totalFieldsScanned} fields checked');
    buffer.writeln();
    buffer.writeln('Tick what you want to act on, then run '
        '`amscan remove` to delete it or `amscan disable` to comment it out.');
    buffer.writeln();
    buffer.writeln('Ticking a class or field selects everything under it. '
        'Ticking `field declaration` takes the whole field, since nothing '
        'else can reference a field that no longer exists. '
        'With nothing ticked, both commands offer to act on everything.');
    buffer.writeln();
    buffer.writeln('Every row links twice, because no single link works '
        'everywhere: **line N** is relative and opens in Android Studio / '
        'IntelliJ (and VS Code), while **VS Code** is the only form that '
        'reliably lands the cursor on the exact line.');
    buffer.writeln();
    buffer.writeln('- [ ] **SELECT EVERYTHING**');
    buffer.writeln();

    final byFile = <String, List<CachedField>>{};
    for (final field in cache.fields) {
      byFile.putIfAbsent(field.filePath, () => []).add(field);
    }

    for (final fileEntry in byFile.entries) {
      final filePath = fileEntry.key;
      final plans = _plans(filePath, fileEntry.value);

      final byClass = <String, List<CachedField>>{};
      for (final field in fileEntry.value) {
        byClass.putIfAbsent(field.className, () => []).add(field);
      }

      for (final classEntry in byClass.entries) {
        final className = classEntry.key;

        buffer.writeln('---');
        buffer.writeln();
        buffer.writeln('## $className');
        buffer.writeln();
        buffer.writeln('└ ${_relative(
          p.relative(filePath, from: cache.projectRoot),
          filePath,
        )}');
        buffer.writeln();
        buffer.writeln('- [ ] **All of `$className`**');
        buffer.writeln();

        if (cache.deadClasses.containsKey(className)) {
          buffer.writeln('> 💀 **`$className` is dead.** Every field is '
              'unused, and nothing outside the code being removed still names '
              'the type. Ticking this class deletes the whole declaration, '
              'and any field of type `$className` in another model goes with '
              'it.');
          buffer.writeln();
        }

        for (final field in classEntry.value) {
          final edits = plans['$className.${field.fieldName}'] ?? const <Edit>[];

          buffer.writeln('- [ ] **`${field.fieldName}`** · '
              '${edits.length} part${edits.length == 1 ? '' : 's'}');

          if (edits.isEmpty) {
            buffer.writeln('  - ⚠️ No removable declaration found — the '
                'source may have changed since the scan.');
            buffer.writeln();
            continue;
          }

          final width =
              edits.map((e) => e.label.length).reduce((a, b) => a > b ? a : b);

          for (final edit in edits) {
            buffer.writeln(
              '  - [ ] `${edit.label.padRight(width)}` '
              '${_relative('line ${edit.line}', filePath, edit.line)} · '
              '${_vscode('VS Code', filePath, edit.line)}',
            );
          }
          buffer.writeln();
        }
      }
    }

    return buffer.toString();
  }

  /// Computes each field's removal plan against the current source, so every
  /// listed part is attributable to the field that causes it.
  Map<String, List<Edit>> _plans(String filePath, List<CachedField> fields) {
    final plans = <String, List<Edit>>{};

    final file = File(filePath);
    if (!file.existsSync()) {
      return plans;
    }

    final String content;
    try {
      content = file.readAsStringSync();
    } catch (_) {
      return plans;
    }

    for (final field in fields) {
      try {
        final result = ModelFieldFixer.removeFields(
          content: content,
          path: filePath,
          className: field.className,
          fieldNames: {field.fieldName},
        );
        plans['${field.className}.${field.fieldName}'] = result.edits;
      } catch (_) {
        // Left absent; the report notes it as unresolvable.
      }
    }

    return plans;
  }

  /// A relative Markdown link, optionally carrying an `#L<n>` fragment.
  ///
  /// This is the form JetBrains' Markdown preview will follow — and the only
  /// one that resolves anywhere but the machine that wrote the file. Editors
  /// vary on whether the fragment moves the cursor; most just open the file.
  String _relative(String text, String target, [int? line]) {
    final relative = p.relative(target, from: directory);
    final fragment = line == null ? '' : '#L$line';
    return '[$text]($relative$fragment)';
  }

  /// `vscode://file/<path>:<line>:<col>` — the one form that reliably puts
  /// the cursor on the line, and only in VS Code. Absolute, so it means
  /// nothing off this machine; harmless for a report that lives in
  /// `.dart_tool/` and is never shared.
  String _vscode(String text, String target, [int? line]) {
    final encoded = Uri.encodeFull(p.absolute(target));
    final position = line == null ? '' : ':$line:1';
    return '[$text](vscode://file$encoded$position)';
  }

  String _formatTime(DateTime time) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}';
  }
}
