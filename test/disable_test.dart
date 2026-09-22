import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:api_model_scanner/api_model_scanner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _model = '''
class HomeBanner {
  final String? desktop;
  final String? mobile;

  const HomeBanner({this.desktop, this.mobile});

  factory HomeBanner.fromJson(Map<String, dynamic> json) => HomeBanner(
        desktop: json['desktop']?.toString(),
        mobile: json['mobile']?.toString(),
      );

  Map<String, dynamic> toJson() => {
        if (desktop != null) 'desktop': desktop,
        if (mobile != null) 'mobile': mobile,
      };
}
''';

List<Edit> planFor(String field) => ModelFieldFixer.removeFields(
      content: _model,
      path: 'banner.dart',
      className: 'HomeBanner',
      fieldNames: {field},
    ).edits;

/// Parses [source] and fails the test if it has syntax errors.
void expectParses(String source) {
  final result = parseString(content: source, throwIfDiagnostics: false);
  expect(
    result.errors.where((e) => e.severity.name.toLowerCase() == 'error'),
    isEmpty,
    reason: 'generated source does not parse:\n$source',
  );
}

void main() {
  group('the record survives emptying', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('amscan_rec'));
    tearDown(() => temp.deleteSync(recursive: true));

    DisabledField entry() => DisabledField(
          className: 'M',
          fieldName: 'spare',
          filePath: p.join(temp.path, 'lib', 'm.dart'),
          snippets: const [DisabledSnippet('String? spare;', occurrence: 0)],
          disabledAt: DateTime(2026),
          line: 3,
        );

    test('emptying it leaves the file for `clear` to remove', () {
      final store = DisabledStore(temp.path);
      store.write([entry()]);
      expect(store.exists, isTrue);

      store.write([]);

      expect(store.exists, isTrue, reason: 'only `clear` removes it');
      expect(store.isEmpty, isTrue, reason: 'emptiness is read, not inferred');
      expect(store.read(), isEmpty);
    });

    test('the declaration line round-trips, so undo can hand it back', () {
      final store = DisabledStore(temp.path);
      store.write([entry()]);

      expect(store.read().single.line, 3);
    });

    test('a record written before lines were kept reads as zero', () {
      final legacy = DisabledField.fromJson({
        'class': 'M',
        'field': 'spare',
        'file': '/tmp/m.dart',
        'snippets': ['String? spare;'],
        'disabledAt': DateTime(2026).toIso8601String(),
      });

      expect(legacy.line, 0);
    });
  });


  test('commenting the whole field keeps the source parseable', () {
    final out = ModelFieldFixer.applyEdits(
      _model,
      planFor('desktop'),
      EditMode.comment,
    );

    expectParses(out);
    // The code is still there, just neutralised.
    expect(out, contains('/*'));
    expect(out, contains('*/'));
    expect(out, contains('desktop'));
    // The still-used field is untouched.
    expect(out, contains('final String? mobile;'));
  });

  test('a mid-line range is commented without breaking its neighbours', () {
    // `this.desktop` sits inline with `this.mobile` on one line, so it can
    // only be neutralised with a block comment, never a line comment.
    final ctor = planFor('desktop')
        .where((e) => e.label.startsWith('constructor parameter'))
        .toList();
    expect(ctor, hasLength(1));

    final out = ModelFieldFixer.applyEdits(_model, ctor, EditMode.comment);

    expectParses(out);
    expect(out, contains('this.mobile'));
    expect(out, contains('/*this.desktop,*/'));
  });

  test('commenting does not swallow indentation or the trailing newline', () {
    final declaration = planFor('desktop')
        .where((e) => e.label == 'field declaration')
        .toList();

    final out = ModelFieldFixer.applyEdits(_model, declaration, EditMode.comment);

    expectParses(out);
    // Indentation stays outside the comment, and the line break survives.
    expect(out, contains('  /*final String? desktop;*/\n'));
  });

  test('a single toJson entry can be disabled on its own', () {
    final mapEntry =
        planFor('desktop').where((e) => e.label == 'map entry').toList();
    expect(mapEntry, hasLength(1));

    final out = ModelFieldFixer.applyEdits(_model, mapEntry, EditMode.comment);

    expectParses(out);
    // The field itself survives; only the serialization entry is off.
    expect(out, contains('final String? desktop;'));
    expect(out, contains("if (mobile != null) 'mobile': mobile,"));
  });

  test('delete mode still removes rather than comments', () {
    final out = ModelFieldFixer.applyEdits(
      _model,
      planFor('desktop'),
      EditMode.delete,
    );

    expectParses(out);
    expect(out.contains('desktop'), isFalse);
    expect(out.contains('/*'), isFalse);
  });

  test('an empty edit list leaves the source untouched', () {
    expect(
      ModelFieldFixer.applyEdits(_model, const [], EditMode.comment),
      _model,
    );
  });
}
