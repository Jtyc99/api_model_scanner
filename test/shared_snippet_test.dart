import 'package:api_model_scanner/src/cache/disabled_plan.dart';
import 'package:api_model_scanner/src/cache/disabled_store.dart';
import 'package:test/test.dart';

DisabledField field(String name, List<DisabledSnippet> snippets) =>
    DisabledField(
      className: 'Model',
      fieldName: name,
      filePath: '/tmp/model.dart',
      snippets: snippets,
      disabledAt: DateTime(2026),
    );

/// A range that several fields share — the whole `hashCode` getter, taken
/// because every one of its operands was going — is recorded under each of
/// those fields, and must move only when all of them do.
const _shared = '''@override
  int get hashCode => a.hashCode ^ b.hashCode;''';

const _disabled = '''
class Model {
  /*String? a;*/
  /*String? b;*/

  /*$_shared*/
}
''';

void main() {
  group('a range shared by several fields', () {
    final a = field('a', [
      const DisabledSnippet('String? a;', occurrence: 0),
      const DisabledSnippet(_shared, occurrence: 0),
    ]);
    final b = field('b', [
      const DisabledSnippet('String? b;', occurrence: 0),
      const DisabledSnippet(_shared, occurrence: 0),
    ]);

    test('is recognised as owned by both', () {
      final plan = resolveDisabled(_disabled, [a, b]);
      final sharedRange = plan.ranges.singleWhere((r) => r.text == _shared);
      expect(sharedRange.owners, {a.key, b.key});
      expect(sharedRange.isShared, isTrue);
      expect(plan.unresolved, isEmpty);
    });

    test('moves when every owner is selected', () {
      final plan = resolveDisabled(_disabled, [a, b]);
      final out = applyRanges(_disabled, plan.ranges, restore: true);
      expect(out, isNot(contains('/*')));
      expect(out, contains('String? a;'));
      expect(out, contains('String? b;'));
      expect(out, contains('int get hashCode'));
    });

    test('holds back the whole field when one owner is not selected', () {
      final plan = resolveDisabled(_disabled, [a, b]);
      final selected = {a.key};

      // Mirrors the runner: a shared range nobody can move pins every other
      // range its owners hold, so `a` does not move either.
      final blocked = <String>{};
      for (final range in plan.ranges) {
        if (range.owners.difference(selected).isNotEmpty) {
          blocked.addAll(range.owners.intersection(selected));
        }
      }
      var settling = true;
      while (settling) {
        settling = false;
        for (final range in plan.ranges) {
          if (range.owners.any(blocked.contains)) {
            for (final owner in range.owners) {
              if (blocked.add(owner)) settling = true;
            }
          }
        }
      }
      expect(blocked, contains(a.key));

      final moving = plan.ranges
          .where((r) =>
              r.owners.every(selected.contains) &&
              !r.owners.any(blocked.contains))
          .toList();
      expect(moving, isEmpty);

      // Nothing moved: a half-restored field would leave its own `fromJson`
      // naming a declaration that is still commented out.
      expect(applyRanges(_disabled, moving, restore: true), _disabled);
    });
  });

  group('byte-identical ranges', () {
    // The private-field/getter style produces `num? id,` twice in one class:
    // once as a constructor parameter, once in `copyWith`.
    const twice = '''
class Announcements {
  /*num? _id;*/

  Announcements({
    /*num? id,*/
    String? type,
  });

  Announcements copyWith({
    /*num? id,*/
    String? type,
  });
}
''';

    test('are told apart and both restored', () {
      final only = field('_id', [
        const DisabledSnippet('num? _id;', occurrence: 0),
        const DisabledSnippet('num? id,', occurrence: 0),
        const DisabledSnippet('num? id,', occurrence: 1),
      ]);

      final plan = resolveDisabled(twice, [only]);
      expect(plan.ranges.where((r) => r.text == 'num? id,').length, 2);

      final out = applyRanges(twice, plan.ranges, restore: true);
      expect(out, isNot(contains('/*')));
      expect(RegExp(r'num\? id,').allMatches(out).length, 2);
    });

    test('resolve to distinct positions', () {
      final only = field('_id', [
        const DisabledSnippet('num? id,', occurrence: 0),
        const DisabledSnippet('num? id,', occurrence: 1),
      ]);
      final plan = resolveDisabled(twice, [only]);
      final starts = plan.ranges.map((r) => r.start).toSet();
      expect(starts.length, 2, reason: 'two ranges, two positions');
    });
  });

  group('records from the old format', () {
    test('a bare string still resolves', () {
      final legacy = DisabledField.fromJson({
        'class': 'Model',
        'field': 'a',
        'file': '/tmp/model.dart',
        'snippets': ['String? a;'],
        'disabledAt': DateTime(2026).toIso8601String(),
      });
      expect(legacy.snippets.single.occurrence, isNull);

      final plan = resolveDisabled(_disabled, [legacy]);
      expect(plan.unresolved, isEmpty);
      expect(plan.ranges.single.text, 'String? a;');

      final out = applyRanges(_disabled, plan.ranges, restore: true);
      expect(out, contains('String? a;'));
      expect(out, isNot(contains('/*String? a;*/')));
    });

    test('round-trips through json unchanged', () {
      final original = field('a', [
        const DisabledSnippet('String? a;', occurrence: 2),
        const DisabledSnippet('x'),
      ]);
      final back = DisabledField.fromJson(original.toJson());
      expect(back.snippets[0].text, 'String? a;');
      expect(back.snippets[0].occurrence, 2);
      expect(back.snippets[1].occurrence, isNull);
      // An anchored snippet serialises as an object, a legacy one as a string.
      expect(original.toJson()['snippets'], [
        {'text': 'String? a;', 'at': 2},
        'x',
      ]);
    });
  });

  test('code edited since being disabled is reported, not guessed at', () {
    final gone = field('a', [const DisabledSnippet('String? nonsense;')]);
    final plan = resolveDisabled(_disabled, [gone]);
    expect(plan.ranges, isEmpty);
    expect(plan.unresolved, contains(gone.key));
  });
}
