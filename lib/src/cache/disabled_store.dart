import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../cli/targets.dart';
import '../model.dart';
import 'report.dart';
import 'selection.dart';
import 'unused_cache.dart';

/// One commented-out range, as text plus where in the file it sits.
///
/// Text alone does not identify a range. A single field routinely produces
/// two byte-identical ones — `num? id,` as a constructor parameter and again
/// in `copyWith` — so an undo driven by text would put the first one back
/// twice and leave the second commented for good. [occurrence] disambiguates
/// them: it is the index of this range among the identically-worded ranges in
/// the same file, counting from the top.
class DisabledSnippet {
  final String text;

  /// Null on records written before ranges were anchored. Those resolve
  /// positionally instead, which is what the old format could do anyway.
  final int? occurrence;

  const DisabledSnippet(this.text, {this.occurrence});

  dynamic toJson() =>
      occurrence == null ? text : {'text': text, 'at': occurrence};

  /// Accepts the old shape — a bare string — so an existing record keeps
  /// working rather than being silently dropped and stranding the code.
  factory DisabledSnippet.fromJson(dynamic json) {
    if (json is String) {
      return DisabledSnippet(json);
    }
    final map = json as Map<String, dynamic>;
    return DisabledSnippet(
      map['text'] as String,
      occurrence: map['at'] as int?,
    );
  }

  @override
  String toString() => occurrence == null ? text : '$text #$occurrence';
}

/// One field that has been commented out, with the exact ranges that were
/// wrapped. Storing them verbatim is what lets `--undo` put the code back and
/// `--remove` delete it, without having to guess which comments are ours.
class DisabledField {
  final String className;
  final String fieldName;
  final String filePath;
  final List<DisabledSnippet> snippets;
  final DateTime disabledAt;

  /// One-based declaration line, carried so `--undo` can put the field back
  /// into the unused record rather than dropping it on the floor.
  final int line;

  /// Reads of a field by this name through a `dynamic` receiver, as the scan
  /// found them. Carried through the record so a field keeps its standing:
  /// `--remove` guards it the way `remove` did, and `--undo` hands it back to
  /// the section it came from rather than to the table everything acts on.
  final List<DynamicRead> dynamicReads;

  /// Whether [dynamicReads] is an answer. False on a record written before
  /// the check existed; `--remove` and `--undo` look before acting on it.
  final bool dynamicChecked;

  const DisabledField({
    required this.className,
    required this.fieldName,
    required this.filePath,
    required this.snippets,
    required this.disabledAt,
    this.line = 0,
    this.dynamicReads = const [],
    this.dynamicChecked = false,
  });

  String get key => '$filePath|$className|$fieldName';

  /// `file|Class.field`, the key a [Selection] uses for this field.
  String get selectionKey => '${classKey(filePath, className)}.$fieldName';

  bool get readDynamically => dynamicReads.isNotEmpty;

  /// This field as the unused record lists it, for `--undo` to hand back.
  ///
  /// With its reads: without them a field that was held apart comes back
  /// into the table that SELECT EVERYTHING and `--all` act on — the very
  /// removal it was held apart from.
  CachedField toCachedField() => CachedField(
        className: className,
        fieldName: fieldName,
        filePath: filePath,
        line: line,
        dynamicReads: dynamicReads,
        dynamicChecked: dynamicChecked,
      );

  /// This record, checked: [reads] is what the check found, if anything.
  DisabledField withDynamicReads(List<DynamicRead> reads) => DisabledField(
        className: className,
        fieldName: fieldName,
        filePath: filePath,
        snippets: snippets,
        disabledAt: disabledAt,
        line: line,
        dynamicReads: reads,
        dynamicChecked: true,
      );

  List<String> get texts => [for (final s in snippets) s.text];

  DisabledField withSnippets(List<DisabledSnippet> kept) => DisabledField(
        className: className,
        fieldName: fieldName,
        filePath: filePath,
        snippets: kept,
        disabledAt: disabledAt,
        line: line,
        dynamicReads: dynamicReads,
        dynamicChecked: dynamicChecked,
      );

  Map<String, dynamic> toJson() => {
        'class': className,
        'field': fieldName,
        'file': filePath,
        'line': line,
        'snippets': [for (final s in snippets) s.toJson()],
        'disabledAt': disabledAt.toIso8601String(),
        if (dynamicReads.isNotEmpty)
          'dynamicReads': [for (final read in dynamicReads) read.toJson()],
        if (dynamicChecked) 'checked': true,
      };

  factory DisabledField.fromJson(Map<String, dynamic> json) => DisabledField(
        className: json['class'] as String,
        fieldName: json['field'] as String,
        filePath: json['file'] as String,
        snippets: [
          for (final s in json['snippets'] as List<dynamic>)
            DisabledSnippet.fromJson(s),
        ],
        disabledAt: DateTime.parse(json['disabledAt'] as String),
        line: (json['line'] as int?) ?? 0,
        // A record written before dynamic reads were kept has neither key,
        // and loads as unchecked, so the command acting on it looks first.
        dynamicReads: [
          for (final read in json['dynamicReads'] as List<dynamic>? ?? const [])
            DynamicRead.fromJson(read as Map<String, dynamic>),
        ],
        dynamicChecked: json['checked'] == true,
      );
}

/// Records fields that are currently commented out.
///
/// The files exist only while something is disabled: clearing the last entry
/// deletes them, so their presence always means "there is disabled code here".
class DisabledStore {
  final String projectRoot;

  DisabledStore(this.projectRoot);

  String get directory =>
      p.join(projectRoot, '.dart_tool', 'api_model_scanner');

  String get jsonPath => p.join(directory, 'disabled_fields.json');

  String get reportPath => p.join(directory, 'disabled_fields.md');

  bool get exists => File(jsonPath).existsSync();

  List<DisabledField> read() {
    final file = File(jsonPath);
    if (!file.existsSync()) {
      return [];
    }
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      return (json['fields'] as List<dynamic>)
          .map((e) => DisabledField.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Merges [added] into the record, replacing any entry for the same field.
  void add(List<DisabledField> added) {
    final byKey = {for (final f in read()) f.key: f};
    for (final field in added) {
      byKey[field.key] = field;
    }
    write(byKey.values.toList());
  }

  /// Drops the given fields, deleting the files when nothing is left.
  void remove(Iterable<String> keys) {
    final remaining = read().where((f) => !keys.contains(f.key)).toList();
    write(remaining);
  }

  /// Whether anything is currently commented out.
  ///
  /// Content, not presence: the files persist once written so that `clear` is
  /// the only thing that removes them, which means their existence no longer
  /// says anything about whether code is disabled.
  bool get isEmpty => read().isEmpty;

  void write(List<DisabledField> fields) {
    Directory(directory).createSync(recursive: true);
    File(jsonPath).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'fields': fields.map((f) => f.toJson()).toList(),
      }),
    );
    File(reportPath).writeAsStringSync(_render(fields));
  }

  void delete() {
    for (final path in [jsonPath, reportPath]) {
      final file = File(path);
      if (file.existsSync()) {
        file.deleteSync();
      }
    }
  }

  /// Reads back which disabled fields are ticked.
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

  /// Renders the record in the same tickable shape as the unused report, so
  /// undoing part of it works the same way as disabling part of it.
  ///
  /// Snippets are listed without checkboxes on purpose: undoing only some of
  /// a field's snippets would leave, say, a `fromJson` line referring to a
  /// declaration that is still commented out.
  String _render(List<DisabledField> fields) {
    final buffer = StringBuffer();

    final safe = [for (final f in fields) if (!f.readDynamically) f];
    final guarded = [for (final f in fields) if (f.readDynamically) f];

    buffer.writeln('# Disabled API model fields');
    buffer.writeln();
    buffer.writeln('**${fields.length} field${fields.length == 1 ? '' : 's'}** '
        'commented out but still present in the source'
        '${guarded.isEmpty ? '' : ' · ${guarded.length} read dynamically'}.');
    buffer.writeln();
    buffer.writeln('Tick what you want, then run `amscan disable --undo` to '
        'put it back or `amscan disable --remove` to delete it for good. '
        'With nothing ticked, both offer to act on everything'
        '${guarded.isEmpty ? '' : ' — though `--remove` never takes a field '
            'read dynamically without a tick of its own'}.');
    buffer.writeln();
    buffer.writeln('This file disappears once nothing is disabled.');
    buffer.writeln();

    // The same layout as the unused report, and for the same reasons: the few
    // fields read dynamically first, where they cannot be missed, in shapes
    // an older table editor cannot mistake for ordinary rows.
    if (guarded.isNotEmpty) {
      buffer.writeln('---');
      buffer.writeln();
      buffer.writeln('**⚠️ Read dynamically — deleted for good only when you '
          'tick them**');
      buffer.writeln();
      buffer.writeln('A field of the same name was read through a dynamic '
          'receiver when these were disabled, so the app may throw wherever '
          'that read runs until they are back. --undo puts them back along '
          'with everything else; --remove takes one only when it is ticked '
          'itself.');
      buffer.writeln();
      _writeBlocks(buffer, guarded, guarded: true);
    }

    if (safe.isNotEmpty) {
      if (guarded.isNotEmpty) {
        buffer.writeln('---');
        buffer.writeln();
        buffer.writeln('**Disabled — safe to select together**');
        buffer.writeln();
      }
      buffer.writeln('- [ ] **SELECT EVERYTHING**');
      buffer.writeln();
      _writeBlocks(buffer, safe, guarded: false);
    }

    return buffer.toString();
  }

  void _writeBlocks(
    StringBuffer buffer,
    List<DisabledField> fields, {
    required bool guarded,
  }) {
    final bullet = guarded ? '*' : '-';

    final byFile = <String, List<DisabledField>>{};
    for (final field in fields) {
      byFile.putIfAbsent(field.filePath, () => []).add(field);
    }

    for (final entry in byFile.entries) {
      final byClass = <String, List<DisabledField>>{};
      for (final field in entry.value) {
        byClass.putIfAbsent(field.className, () => []).add(field);
      }

      // Relative, so the preview can follow it in either IDE. There is no
      // line to aim at: a disabled range is recorded by its text, and the
      // lines around it have shifted anyway.
      final location = '[${p.relative(entry.key, from: projectRoot)}]'
          '(${p.relative(entry.key, from: directory)})';

      for (final classEntry in byClass.entries) {
        if (guarded) {
          buffer.writeln('### ${classEntry.key}');
          buffer.writeln();
          buffer.writeln('Declared in $location');
          buffer.writeln();
        } else {
          buffer.writeln('---');
          buffer.writeln();
          buffer.writeln('## ${classEntry.key}');
          buffer.writeln();
          buffer.writeln('└ $location');
          buffer.writeln();
          buffer.writeln('- [ ] **All of `${classEntry.key}`**');
          buffer.writeln();
        }

        for (final field in classEntry.value) {
          // The same link form the unused report writes, so both editors can
          // follow a read from either file.
          final reads = !guarded
              ? ''
              : ' · read at ${field.dynamicReads.map((r) => deepLink(
                    text: '${p.relative(r.filePath, from: projectRoot)}'
                        ':${r.line}',
                    file: p.absolute(r.filePath),
                    line: r.line,
                    host: currentHostIde(),
                  )).join(', ')}';
          buffer.writeln('$bullet [ ] **`${field.fieldName}`** · '
              '${field.snippets.length} '
              'snippet${field.snippets.length == 1 ? '' : 's'}$reads');
          for (final snippet in field.snippets) {
            final oneLine =
                snippet.text.replaceAll(RegExp(r'\s+'), ' ').trim();
            final shown = oneLine.length > 88
                ? '${oneLine.substring(0, 88)}…'
                : oneLine;
            buffer.writeln('  $bullet `$shown`');
          }
          buffer.writeln();
        }
      }
    }
  }
}
