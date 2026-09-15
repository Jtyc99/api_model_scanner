/// A public member that exposes a field to the outside world — typically a
/// forwarding getter over a private field:
///
/// ```dart
/// GiftList? _giftList;                     // 0 external references
/// GiftList? get giftList => _giftList;     // the real public API
/// ```
///
/// References to the accessor count as references to the field, otherwise
/// every privately-stored field looks unused.
class FieldAccessor {
  final String name;

  /// Zero-based line of the accessor's name token (LSP convention).
  final int line;

  /// Zero-based column of the accessor's name token (LSP convention).
  final int column;

  const FieldAccessor({
    required this.name,
    required this.line,
    required this.column,
  });

  @override
  String toString() => name;
}

/// An API model class, anchored at its name token so the language server can
/// be asked who references the *type* — not just its fields.
class ModelClass {
  final String className;
  final String filePath;

  /// Zero-based position of the class's name token (LSP convention).
  final int line;
  final int column;

  /// Character offsets of the whole declaration, used to tell whether a
  /// reference falls inside code that is itself being removed.
  final int offset;
  final int end;

  /// Every instance field declared on the class.
  final List<String> fieldNames;

  /// Model types this class holds as fields, e.g. `Person` -> `{Job}`.
  final Set<String> fieldTypes;

  const ModelClass({
    required this.className,
    required this.filePath,
    required this.line,
    required this.column,
    required this.offset,
    required this.end,
    required this.fieldNames,
    required this.fieldTypes,
  });

  @override
  String toString() => className;
}

/// A field declared on an API model class, together with the source location
/// of its name token (used as the anchor for semantic reference lookups).
class ModelField {
  final String className;
  final String fieldName;
  final String filePath;

  /// Zero-based line of the field's name token (LSP convention).
  final int line;

  /// Zero-based column of the field's name token (LSP convention).
  final int column;

  /// Public members that expose this field. A field is only unused when both
  /// it *and* every accessor over it are unreferenced from outside the file.
  final List<FieldAccessor> accessors;

  ModelField({
    required this.className,
    required this.fieldName,
    required this.filePath,
    required this.line,
    required this.column,
    this.accessors = const [],
  });

  @override
  String toString() {
    return '$className.$fieldName';
  }
}

/// A semantic reference to a model field, as reported by the language server.
class Reference {
  final String filePath;
  final int line;
  final int column;

  Reference({required this.filePath, required this.line, required this.column});
}
