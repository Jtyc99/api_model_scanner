import 'package:api_model_scanner/api_model_scanner.dart';
import 'package:test/test.dart';

/// The report names its file, so selection keys are qualified by it — two
/// classes called `HomeBanner` in different files must not share ticks.
const _root = '/proj';
const _file = '/proj/lib/server/response/home_banner.dart';
final _scope = classKey(_file, 'HomeBanner');

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
      final selection = parseSelection(report(), projectRoot: _root);
      expect(selection.isEmpty, isTrue);
      expect(selection.markedCount, 0);
    });

    test('ticking the top box selects everything', () {
      final selection = parseSelection(report(all: 'x'), projectRoot: _root);
      expect(selection.all, isTrue);
      expect(selection.selectsWholeField(_file, 'Anything', 'atAll'), isTrue);
    });

    test('an uppercase X counts as ticked', () {
      final selection = parseSelection(report(field: 'X'), projectRoot: _root);
      expect(selection.fields, contains('$_scope.desktop'));
    });

    test('a ticked class selects all of its fields', () {
      final selection = parseSelection(report(cls: 'x'), projectRoot: _root);
      expect(selection.classes, {_scope});
      expect(selection.selectsWholeField(_file, 'HomeBanner', 'anything'), isTrue);
      expect(selection.selectsWholeField(_file, 'User', 'anything'), isFalse);
    });

    test('a ticked field selects all of its parts', () {
      final selection = parseSelection(report(field: 'x'), projectRoot: _root);
      expect(selection.fields, {'$_scope.desktop'});
      expect(selection.selectsPart(_file, 'HomeBanner', 'desktop', 7), isTrue);
      expect(selection.selectsPart(_file, 'HomeBanner', 'alt', 0), isFalse);
    });

    test('parts are indexed by their order under the field', () {
      final selection = parseSelection(report(parts: [' ', ' ', ' ', 'x']), projectRoot: _root);
      expect(selection.parts, {'$_scope.desktop#3'});
      expect(selection.selectsPart(_file, 'HomeBanner', 'desktop', 3), isTrue);
      expect(selection.selectsPart(_file, 'HomeBanner', 'desktop', 0), isFalse);
    });

    test('several ticked parts are all captured', () {
      final selection = parseSelection(report(parts: ['x', ' ', 'x', ' ']), projectRoot: _root);
      expect(selection.parts, {'$_scope.desktop#0', '$_scope.desktop#2'});
    });

    test('the class name comes from the heading, not the label', () {
      final selection = parseSelection('''
## RealName

└ [lib/a.dart](x)

- [x] **All of `StaleLabel`**
''', projectRoot: _root);
      expect(selection.classes, {classKey('/proj/lib/a.dart', 'RealName')});
    });

    test('fields in different classes do not collide', () {
      final selection = parseSelection('''
## A

└ [lib/a.dart](x)

- [ ] **All of `A`**

- [x] **`id`** · 1 part
  - [ ] `field declaration` [line 1](x)

## B

└ [lib/b.dart](x)

- [ ] **All of `B`**

- [ ] **`id`** · 1 part
  - [x] `field declaration` [line 1](x)
''', projectRoot: _root);
      final a = classKey('/proj/lib/a.dart', 'A');
      final b = classKey('/proj/lib/b.dart', 'B');
      expect(selection.fields, {'$a.id'});
      expect(selection.parts, {'$b.id#0'});
    });

    test('two classes with the same name do not share ticks', () {
      // A models tree routinely declares one `Gift` per endpoint. Keyed by
      // name alone, ticking either would select both of their fields.
      final selection = parseSelection('''
## Gift

└ [lib/plinko/gift.dart](x)

- [x] **All of `Gift`**

- [ ] **`name`** · 1 part
  - [ ] `field declaration` [line 1](x)

## Gift

└ [lib/campaign/gift.dart](x)

- [ ] **All of `Gift`**

- [ ] **`name`** · 1 part
  - [ ] `field declaration` [line 1](x)
''', projectRoot: _root);

      const plinko = '/proj/lib/plinko/gift.dart';
      const campaign = '/proj/lib/campaign/gift.dart';

      expect(selection.selectsWholeField(plinko, 'Gift', 'name'), isTrue);
      expect(
        selection.selectsWholeField(campaign, 'Gift', 'name'),
        isFalse,
        reason: 'the other Gift was not ticked',
      );
    });

    test('a block with no path line selects nothing', () {
      // Without a file there is no way to say which class is meant, and
      // guessing would be how ticks leak between same-named classes.
      final selection = parseSelection('''
## Gift

- [x] **All of `Gift`**
''', projectRoot: _root);

      expect(selection.isEmpty, isTrue);
    });

    test('prose and links without checkboxes are ignored', () {
      final selection = parseSelection('''
# Unused API model fields
Some text with a [link](vscode://file/x.dart:3:1) in it.
''', projectRoot: _root);
      expect(selection.isEmpty, isTrue);
    });

    test('no report at all parses as an empty selection', () {
      expect(parseSelection('', projectRoot: _root).isEmpty, isTrue);
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
      expect(selectedEdits(_file, 'HomeBanner', 'desktop', full, empty), isEmpty);
    });

    test('select-all yields every part', () {
      final result = selectedEdits(
        _file,
        'HomeBanner',
        'desktop',
        full,
        const Selection(all: true),
      );
      expect(result, hasLength(4));
    });

    test('a single non-declaration part yields just that part', () {
      final result = selectedEdits(
        _file,
        'HomeBanner',
        'desktop',
        full,
        Selection(parts: {'$_scope.desktop#3'}),
      );
      expect(result.map((e) => e.label), ['map entry']);
    });

    test('several parts yield exactly those parts, in order', () {
      final result = selectedEdits(
        _file,
        'HomeBanner',
        'desktop',
        full,
        Selection(parts: {'$_scope.desktop#3', '$_scope.desktop#2'}),
      );
      expect(result.map((e) => e.label), [
        'named argument desktop',
        'map entry',
      ]);
    });

    test('selecting the declaration promotes to the whole field', () {
      // Nothing may still reference a field whose declaration is gone.
      final result = selectedEdits(
        _file,
        'HomeBanner',
        'desktop',
        full,
        Selection(parts: {'$_scope.desktop#0'}),
      );
      expect(result, hasLength(4));
    });

    test('parts of another field are not picked up', () {
      final result = selectedEdits(
        _file,
        'HomeBanner',
        'desktop',
        full,
        const Selection(parts: {'HomeBanner.alt#1'}),
      );
      expect(result, isEmpty);
    });

    test('an empty plan yields nothing even when selected', () {
      expect(
        selectedEdits(_file, 'HomeBanner', 'gone', const [], const Selection(all: true)),
        isEmpty,
      );
    });
  });
}
