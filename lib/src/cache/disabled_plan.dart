import 'disabled_store.dart';

/// One commented-out range in a file, resolved to a concrete position and
/// tied to every field that recorded it.
class DisabledRange {
  /// Offset of the opening `/*`.
  final int start;

  /// Offset just past the closing `*/`.
  final int end;

  final String text;

  /// `DisabledField.key` of every field that claims this range. More than one
  /// is normal: a `hashCode` getter taken whole because all its operands were
  /// going is recorded under each of those fields.
  final Set<String> owners;

  DisabledRange({
    required this.start,
    required this.end,
    required this.text,
    required this.owners,
  });

  bool get isShared => owners.length > 1;
}

/// What [resolveDisabled] worked out for one file.
class DisabledPlan {
  /// Every recorded range that was found in the content, in file order.
  final List<DisabledRange> ranges;

  /// Field keys with at least one range that could not be found at all —
  /// the code was edited after being disabled.
  final Set<String> unresolved;

  const DisabledPlan({required this.ranges, required this.unresolved});
}

/// Locates every range recorded for one file.
///
/// Identifying a range by its text alone is ambiguous, so records are grouped
/// by `(text, occurrence)` — one group per distinct range, however many fields
/// claim it — and the groups for a given text are matched, in recorded order,
/// against the `/*text*/` occurrences actually present.
///
/// Matching by *order* rather than by absolute index is deliberate. Undoing
/// part of a file removes some ranges and shifts the indices of the rest, and
/// rewriting every remaining record afterwards would be one more thing to get
/// wrong. Relative order survives that.
DisabledPlan resolveDisabled(String content, List<DisabledField> fields) {
  // (text, occurrence) -> owners. A null occurrence is a legacy record; each
  // one is its own range, keyed so it cannot collide with an anchored group.
  final groups = <String, Set<String>>{};
  final groupText = <String, String>{};
  final groupOrder = <String, int>{};
  var legacyCounter = 0;
  var seen = 0;

  for (final field in fields) {
    for (final snippet in field.snippets) {
      final id = snippet.occurrence == null
          ? 'legacy:${legacyCounter++}:${snippet.text}'
          : 'at:${snippet.occurrence}:${snippet.text}';
      groupText[id] = snippet.text;
      groupOrder.putIfAbsent(id, () => snippet.occurrence ?? (1 << 30) + seen);
      groups.putIfAbsent(id, () => <String>{}).add(field.key);
      seen++;
    }
  }

  // Where each wording actually appears, top to bottom.
  final positions = <String, List<int>>{};
  for (final text in groupText.values.toSet()) {
    final wrapped = '/*$text*/';
    final found = <int>[];
    var from = 0;
    while (true) {
      final index = content.indexOf(wrapped, from);
      if (index == -1) {
        break;
      }
      found.add(index);
      from = index + wrapped.length;
    }
    positions[text] = found;
  }

  final ranges = <DisabledRange>[];
  final unresolved = <String>{};

  // Groups for one wording, in the order they were recorded, take the
  // occurrences of that wording in the order they appear.
  final byText = <String, List<String>>{};
  for (final id in groupText.keys) {
    byText.putIfAbsent(groupText[id]!, () => []).add(id);
  }

  for (final entry in byText.entries) {
    final text = entry.key;
    final ids = entry.value
      ..sort((a, b) => groupOrder[a]!.compareTo(groupOrder[b]!));
    final found = positions[text]!;

    for (var i = 0; i < ids.length; i++) {
      final owners = groups[ids[i]]!;
      if (i >= found.length) {
        // Recorded but not present: either a sibling already restored it, or
        // the code was edited. Either way this field cannot be completed.
        unresolved.addAll(owners);
        continue;
      }
      ranges.add(DisabledRange(
        start: found[i],
        end: found[i] + '/*$text*/'.length,
        text: text,
        owners: owners,
      ));
    }
  }

  ranges.sort((a, b) => a.start.compareTo(b.start));
  return DisabledPlan(ranges: ranges, unresolved: unresolved);
}

/// Rewrites [content], applying [ranges] from the bottom up so that each
/// offset is still valid when its turn comes.
///
/// [restore] unwraps the comment; otherwise the range is deleted outright.
String applyRanges(
  String content,
  Iterable<DisabledRange> ranges, {
  required bool restore,
}) {
  final ordered = ranges.toList()..sort((a, b) => b.start.compareTo(a.start));
  var result = content;
  for (final range in ordered) {
    result = result.replaceRange(
      range.start,
      range.end,
      restore ? range.text : '',
    );
  }
  return result;
}
