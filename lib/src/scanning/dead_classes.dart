import '../model.dart';

/// A half-open character range in a file that is slated for removal.
class RemovalRange {
  final String filePath;
  final int start;
  final int end;

  const RemovalRange({
    required this.filePath,
    required this.start,
    required this.end,
  });

  bool contains(String path, int offset) =>
      path == filePath && offset >= start && offset < end;
}

/// Where a class is referenced, resolved to character offsets.
class ClassReference {
  final String filePath;
  final int offset;

  const ClassReference({required this.filePath, required this.offset});
}

/// Works out which model classes are dead once the unused fields are gone.
///
/// A class is only ever referenced *somewhere* — `Person.job`'s type
/// annotation is itself a reference to `Job` — so deadness cannot be decided
/// in one pass. Instead this iterates to a fixpoint: a class is dead when
/// every reference to it lies inside code that is itself being removed. Each
/// class that dies deletes its whole body, which may in turn free the last
/// reference to another class.
///
/// If anything real still points at the class — `person.job != null`, a
/// `RootResponse<Job>` signature, a manual construction — that reference sits
/// outside every removal range and the class correctly survives.
Set<String> resolveDeadClasses({
  required List<ModelClass> classes,
  required Set<String> unusedFieldKeys,
  required Map<String, List<ClassReference>> classReferences,
  required List<RemovalRange> fieldRemovals,
}) {
  final byName = {for (final c in classes) c.className: c};

  // Only classes whose every field is already going can ever qualify.
  final candidates = <String>{
    for (final c in classes)
      if (c.fieldNames.isNotEmpty &&
          c.fieldNames.every(
              (f) => unusedFieldKeys.contains('${c.className}.$f')))
        c.className,
  };

  final dead = <String>{};
  var changed = true;

  while (changed) {
    changed = false;

    for (final name in candidates) {
      if (dead.contains(name)) {
        continue;
      }

      final declaration = byName[name]!;
      final references = classReferences[name] ?? const <ClassReference>[];

      final live = references.where((reference) {
        // A mention inside the class's own declaration says nothing.
        if (reference.filePath == declaration.filePath &&
            reference.offset >= declaration.offset &&
            reference.offset < declaration.end) {
          return false;
        }
        // Nor does one inside a field we are already deleting.
        if (fieldRemovals
            .any((r) => r.contains(reference.filePath, reference.offset))) {
          return false;
        }
        // Nor one inside a class that is itself dead.
        for (final other in dead) {
          final body = byName[other]!;
          if (reference.filePath == body.filePath &&
              reference.offset >= body.offset &&
              reference.offset < body.end) {
            return false;
          }
        }
        return true;
      });

      if (live.isEmpty) {
        dead.add(name);
        changed = true;
      }
    }
  }

  return dead;
}
