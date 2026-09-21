import 'dart:convert';

import 'package:path/path.dart' as p;

import '../model.dart';

/// What the user ticked in the report.
///
/// Selection is deliberately action-agnostic: the report records *what* to act
/// on, and the command (`remove` / `disable`) decides *what happens* to it.
class Selection {
  /// The top-level "select everything" box.
  final bool all;

  /// Fully-selected classes, keyed `file|Class`.
  ///
  /// Qualified by file because class names are not unique across a models
  /// tree: two endpoints each declaring a `Gift` is ordinary, and a tick on
  /// one of them must not select the other's fields.
  final Set<String> classes;

  /// Fully-selected fields, keyed `file|Class.field`.
  final Set<String> fields;

  /// Individually selected parts, keyed `file|Class.field#index`.
  final Set<String> parts;

  const Selection({
    this.all = false,
    this.classes = const {},
    this.fields = const {},
    this.parts = const {},
  });

  static const empty = Selection();

  bool get isEmpty =>
      !all && classes.isEmpty && fields.isEmpty && parts.isEmpty;

  bool get isNotEmpty => !isEmpty;

  bool selectsWholeField(String filePath, String className, String fieldName) =>
      all ||
      classes.contains(classKey(filePath, className)) ||
      fields.contains('${classKey(filePath, className)}.$fieldName');

  bool selectsPart(
    String filePath,
    String className,
    String fieldName,
    int index,
  ) =>
      selectsWholeField(filePath, className, fieldName) ||
      parts.contains('${classKey(filePath, className)}.$fieldName#$index');

  /// Total number of distinct things ticked, for reporting.
  int get markedCount =>
      classes.length + fields.length + parts.length + (all ? 1 : 0);
}

/// Line shapes the parser recognises.
///
/// Identity is derived from the document's structure — the `##` heading names
/// the class, an unindented task item names a field, and indented task items
/// are that field's parts in order. Nothing is hidden in the file, so the
/// report stays clean when rendered.
class _Patterns {
  /// `## HomeAnnouncement`
  static final heading = RegExp(r'^#{2}\s+(.+?)\s*$');

  /// `- [x] **SELECT EVERYTHING**`
  static final selectAll =
      RegExp(r'^\s*-\s*\[([ xX])\]\s*\*\*SELECT EVERYTHING\*\*');

  /// `- [x] **All of `HomeAnnouncement`**`
  static final classToggle =
      RegExp(r'^-\s*\[([ xX])\]\s*\*\*All of\s*`([^`]+)`\*\*');

  /// `- [x] **`id`** · 5 parts`  (unindented)
  static final field = RegExp(r'^-\s*\[([ xX])\]\s*\*\*`([^`]+)`\*\*');

  /// `  - [x] `field declaration` [line 6](...)`  (indented)
  static final part = RegExp(r'^\s+-\s*\[([ xX])\]');

  /// `└ [lib/server/response/gift.dart](../../lib/...)` — names the file the
  /// block belongs to, and always precedes its checkboxes.
  static final classFile = RegExp(r'^└\s*\[([^\]]+)\]');
}

bool _ticked(String box) => box.toLowerCase() == 'x';

/// Parses a report's Markdown back into a [Selection].
///
/// Only checkbox states are read; the surrounding text is treated as layout.
/// Parses a report's Markdown back into a [Selection].
///
/// [projectRoot] resolves the path each `## Class` block names, so two blocks
/// with the same heading stay distinct. The renderer always prints that path
/// before any checkbox, so the file is known by the time ticks are read.
Selection parseSelection(String markdown, {required String projectRoot}) {
  var all = false;
  final classes = <String>{};
  final fields = <String>{};
  final parts = <String>{};

  String? currentClass;
  String? currentFile;
  String? currentField;
  var partIndex = 0;

  String? scope() => currentClass == null || currentFile == null
      ? null
      : classKey(currentFile, currentClass);

  for (final line in const LineSplitter().convert(markdown)) {
    final heading = _Patterns.heading.firstMatch(line);
    if (heading != null) {
      currentClass = heading.group(1)!.trim();
      currentFile = null;
      currentField = null;
      partIndex = 0;
      continue;
    }

    final path = _Patterns.classFile.firstMatch(line);
    if (path != null) {
      currentFile = p.normalize(p.join(projectRoot, path.group(1)!));
      continue;
    }

    final selectAll = _Patterns.selectAll.firstMatch(line);
    if (selectAll != null) {
      if (_ticked(selectAll.group(1)!)) {
        all = true;
      }
      continue;
    }

    // Indented items are parts of the field most recently seen.
    final part = _Patterns.part.firstMatch(line);
    if (part != null) {
      final scoped = scope();
      if (scoped != null && currentField != null) {
        if (_ticked(part.group(1)!)) {
          parts.add('$scoped.$currentField#$partIndex');
        }
        partIndex++;
      }
      continue;
    }

    final classToggle = _Patterns.classToggle.firstMatch(line);
    if (classToggle != null) {
      // Trust the heading for the class name; the label is only decoration.
      final scoped = scope();
      if (scoped != null && _ticked(classToggle.group(1)!)) {
        classes.add(scoped);
      }
      currentField = null;
      partIndex = 0;
      continue;
    }

    final field = _Patterns.field.firstMatch(line);
    if (field != null && currentClass != null) {
      currentField = field.group(2)!;
      partIndex = 0;
      final scoped = scope();
      if (scoped != null && _ticked(field.group(1)!)) {
        fields.add('$scoped.$currentField');
      }
      continue;
    }
  }

  return Selection(all: all, classes: classes, fields: fields, parts: parts);
}
