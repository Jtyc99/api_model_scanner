import '../model.dart';

/// A half-open character range in a file that is slated for removal.
class RemovalRange {
  final String filePath;
  final int start;
  final int end;

  /// `Class.field` this range belongs to, so a class that only died because
  /// this field was going can say so.
  final String fieldKey;

  const RemovalRange({
    required this.filePath,
    required this.start,
    required this.end,
    required this.fieldKey,
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

/// Works out which model classes are dead once the unused fields are gone,
/// and what each verdict depends on.
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
///
/// Each verdict comes with the `Class.field` keys it rests on. Deadness is
/// decided here against *every* unused field, but the user may then tick only
/// some of them, and a class whose last reference was in a field they did not
/// tick is not dead at all. Returning the conditions lets the apply step
/// re-check them against the real selection instead of trusting an assumption
/// made before anyone chose anything.
Map<String, Set<String>> resolveDeadClasses({
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

  final dead = <String, Set<String>>{};
  var changed = true;

  while (changed) {
    changed = false;

    for (final name in candidates) {
      if (dead.containsKey(name)) {
        continue;
      }

      final declaration = byName[name]!;
      final references = classReferences[name] ?? const <ClassReference>[];

      // What would have to go with it for this verdict to hold.
      final requires = <String>{};
      var alive = false;

      for (final reference in references) {
        // A mention inside the class's own declaration says nothing.
        if (reference.filePath == declaration.filePath &&
            reference.offset >= declaration.offset &&
            reference.offset < declaration.end) {
          continue;
        }

        // Inside a field being deleted: note which one, because the verdict
        // only stands if that field is still going when the edit is applied.
        final covering = fieldRemovals.where(
            (r) => r.contains(reference.filePath, reference.offset));
        if (covering.isNotEmpty) {
          requires.add(covering.first.fieldKey);
          continue;
        }

        // Inside a class that is itself dead: inherit its conditions, and
        // require everything that class needs in order to go.
        String? insideDead;
        for (final other in dead.keys) {
          final body = byName[other]!;
          if (reference.filePath == body.filePath &&
              reference.offset >= body.offset &&
              reference.offset < body.end) {
            insideDead = other;
            break;
          }
        }
        if (insideDead != null) {
          requires.addAll(dead[insideDead]!);
          for (final field in byName[insideDead]!.fieldNames) {
            requires.add('$insideDead.$field');
          }
          continue;
        }

        alive = true;
        break;
      }

      if (!alive) {
        dead[name] = requires;
        changed = true;
      }
    }
  }

  return dead;
}
