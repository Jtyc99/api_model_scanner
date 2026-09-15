import 'package:api_model_scanner/api_model_scanner.dart';
import 'package:test/test.dart';

/// Builds a plan-like list of edits with the given labels.
List<Edit> plan(List<String> labels) => [
      for (var i = 0; i < labels.length; i++)
        Edit(i * 10, i * 10 + 5, labels[i], i + 1),
    ];

const _labels = [
  'field declaration',
  'constructor parameter desktop',
  'named argument desktop',
  'map entry',
];

/// A report in the real rendered shape, with configurable checkbox states.
String report({
  String all = ' ',
  String cls = ' ',
  String field = ' ',
  List<String> parts = const [' ', ' ', ' ', ' '],
}) =>
    '''
# Unused API model fields

- [$all] **SELECT EVERYTHING**

---

## HomeBanner

└ [lib/server/response/home_banner.dart](vscode://file/x.dart)

- [$cls] **All of `HomeBanner`**

- [$field] **`desktop`** · 4 parts
  - [${parts[0]}] `field declaration            ` [line 2](vscode://file/x.dart:2:1)
  - [${parts[1]}] `constructor parameter desktop` [line 7](vscode://file/x.dart:7:1)
  - [${parts[2]}] `named argument desktop       ` [line 10](vscode://file/x.dart:10:1)
  - [${parts[3]}] `map entry                    ` [line 17](vscode://file/x.dart:17:1)
''';

void main() {
  group('parsing', () {
    test('an untouched report selects nothing', () {
      final selection = parseSelection(report());
      expect(selection.isEmpty, isTrue);
      expect(selection.markedCount, 0);
    });

    test('ticking the top box selects everything', () {
      final selection = parseSelection(report(all: 'x'));
      expect(selection.all, isTrue);
      expect(selection.selectsWholeField('Anything', 'atAll'), isTrue);
    });

    test('an uppercase X counts as ticked', () {
      final selection = parseSelection(report(field: 'X'));
      expect(selection.fields, contains('HomeBanner.desktop'));
    });

    test('a ticked class selects all of its fields', () {
      final selection = parseSelection(report(cls: 'x'));
      expect(selection.classes, {'HomeBanner'});
      expect(selection.selectsWholeField('HomeBanner', 'anything'), isTrue);
      expect(selection.selectsWholeField('User', 'anything'), isFalse);
    });

    test('a ticked field selects all of its parts', () {
      final selection = parseSelection(report(field: 'x'));
      expect(selection.fields, {'HomeBanner.desktop'});
      expect(selection.selectsPart('HomeBanner', 'desktop', 7), isTrue);
      expect(selection.selectsPart('HomeBanner', 'alt', 0), isFalse);
    });

    test('parts are indexed by their order under the field', () {
      final selection = parseSelection(report(parts: [' ', ' ', ' ', 'x']));
      expect(selection.parts, {'HomeBanner.desktop#3'});
      expect(selection.selectsPart('HomeBanner', 'desktop', 3), isTrue);
      expect(selection.selectsPart('HomeBanner', 'desktop', 0), isFalse);
    });

    test('several ticked parts are all captured', () {
      final selection = parseSelection(report(parts: ['x', ' ', 'x', ' ']));
      expect(selection.parts, {'HomeBanner.desktop#0', 'HomeBanner.desktop#2'});
    });

    test('the class name comes from the heading, not the label', () {
      final selection = parseSelection('''
## RealName

- [x] **All of `StaleLabel`**
''');
      expect(selection.classes, {'RealName'});
    });

    test('fields in different classes do not collide', () {
      final selection = parseSelection('''
## A

- [ ] **All of `A`**

- [x] **`id`** · 1 part
  - [ ] `field declaration` [line 1](x)

## B

- [ ] **All of `B`**

- [ ] **`id`** · 1 part
  - [x] `field declaration` [line 1](x)
''');
      expect(selection.fields, {'A.id'});
      expect(selection.parts, {'B.id#0'});
    });

    test('prose and links without checkboxes are ignored', () {
      final selection = parseSelection('''
# Unused API model fields
Some text with a [link](vscode://file/x.dart:3:1) in it.
''');
      expect(selection.isEmpty, isTrue);
    });

    test('no report at all parses as an empty selection', () {
      expect(parseSelection('').isEmpty, isTrue);
    });

    test('the rendered report carries no stray markers', () {
      // The old design leaked `<!--...-->` into the rendered output.
      expect(report().contains('<!--'), isFalse);
      expect(report().contains('!--'), isFalse);
    });
  });

  group('selectedEdits', () {
    final full = plan(_labels);
    const empty = Selection();

    test('nothing selected yields no edits', () {
      expect(selectedEdits('HomeBanner', 'desktop', full, empty), isEmpty);
    });

    test('select-all yields every part', () {
      final result = selectedEdits(
        'HomeBanner',
        'desktop',
        full,
        const Selection(all: true),
      );
      expect(result, hasLength(4));
    });

    test('a single non-declaration part yields just that part', () {
      final result = selectedEdits(
        'HomeBanner',
        'desktop',
        full,
        const Selection(parts: {'HomeBanner.desktop#3'}),
      );
      expect(result.map((e) => e.label), ['map entry']);
    });

    test('several parts yield exactly those parts, in order', () {
      final result = selectedEdits(
        'HomeBanner',
        'desktop',
        full,
        const Selection(parts: {'HomeBanner.desktop#3', 'HomeBanner.desktop#2'}),
      );
      expect(result.map((e) => e.label), [
        'named argument desktop',
        'map entry',
      ]);
    });

    test('selecting the declaration promotes to the whole field', () {
      // Nothing may still reference a field whose declaration is gone.
      final result = selectedEdits(
        'HomeBanner',
        'desktop',
        full,
        const Selection(parts: {'HomeBanner.desktop#0'}),
      );
      expect(result, hasLength(4));
    });

    test('parts of another field are not picked up', () {
      final result = selectedEdits(
        'HomeBanner',
        'desktop',
        full,
        const Selection(parts: {'HomeBanner.alt#1'}),
      );
      expect(result, isEmpty);
    });

    test('an empty plan yields nothing even when selected', () {
      expect(
        selectedEdits('HomeBanner', 'gone', const [], const Selection(all: true)),
        isEmpty,
      );
    });
  });
}
