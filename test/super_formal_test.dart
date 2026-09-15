import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:api_model_scanner/src/model_field_fixer.dart';
import 'package:test/test.dart';

/// `super.field` is *syntactically* valid even when the superclass no longer
/// declares `field`, so `parseString` cannot see this class of breakage — it
/// is a resolution error (`super_formal_parameter_without_associated_named`).
/// These tests assert on the emitted text instead.
void expectParses(String source, String reason) {
  final result = parseString(content: source, throwIfDiagnostics: false);
  expect(
    result.errors.where((e) => e.severity.name.toLowerCase() == 'error'),
    isEmpty,
    reason: '$reason\n$source',
  );
}

String apply(String source, Set<String> fields, {String className = 'Country'}) {
  final plan = ModelFieldFixer.removeFields(
    content: source,
    path: '/tmp/subject.dart',
    className: className,
    fieldNames: fields,
  );
  return plan.newContent;
}

const _aliasModel = '''
class Country {
  String? id;
  List<String?>? language;

  Country({
    this.id,
    this.language,
  });

  factory Country.fromJson(Map<String, dynamic> json) => Country(
        id: json['id']?.toString(),
        language: json['language'] as List<String?>?,
      );
}

class Currency extends Country {
  Currency({
    super.id,
    super.language,
  });

  factory Currency.fromJson(Map<String, dynamic> json) => Currency(
        id: json['id']?.toString(),
        language: json['language'] as List<String?>?,
      );
}
''';

void main() {
  test('a subclass super formal parameter goes with the field', () {
    final out = apply(_aliasModel, {'language'});
    expect(out, isNot(contains('super.language')));
    expect(out, contains('super.id'));
    expectParses(out, 'alias subclass');
  });

  test('the subclass constructor call drops the named argument too', () {
    final out = apply(_aliasModel, {'language'});
    // Both `Country(...)` and `Currency(...)` must lose `language:`.
    expect(out, isNot(contains('language:')));
    expect(RegExp(r'id:').allMatches(out).length, 2);
  });

  test('a subclass optional group that empties loses its braces', () {
    final out = apply(_aliasModel, {'id', 'language'});
    expect(out, isNot(contains('super.')));
    expect(out, contains('Currency();'));
    expectParses(out, 'emptied subclass group');
  });

  test('an explicit super constructor invocation drops the argument', () {
    const source = '''
class Country {
  String? id;
  List<String?>? language;
  Country({this.id, this.language});
}

class Currency extends Country {
  Currency({List<String?>? language, String? id})
      : super(id: id, language: language);
}
''';
    final out = apply(source, {'language'});
    expect(out, isNot(contains('language: language')));
    expect(out, contains('super(id: id)'));
    expectParses(out, 'explicit super invocation');
  });

  test('removal cascades through a transitive subclass', () {
    const source = '''
class Country {
  String? id;
  List<String?>? language;
  Country({this.id, this.language});
}

class Currency extends Country {
  Currency({super.id, super.language});
}

class LegacyCurrency extends Currency {
  LegacyCurrency({super.id, super.language});
}
''';
    final out = apply(source, {'language'});
    expect(out, isNot(contains('super.language')));
    expect(RegExp(r'super\.id').allMatches(out).length, 2);
    expectParses(out, 'transitive subclass');
  });

  test("a subclass's own like-named parameter is left alone", () {
    const source = '''
class Country {
  String? id;
  List<String?>? language;
  Country({this.id, this.language});
}

class Currency extends Country {
  final String? language;
  Currency({super.id, this.language});
}
''';
    final out = apply(source, {'language'});
    expect(out, isNot(contains('super.language')));
    // The subclass declares its own `language`; that field is not Country's.
    expect(out, contains('this.language'));
    expect(out, contains('final String? language;'));
    expectParses(out, 'shadowing subclass field');
  });

  group('cross-file forwarding', () {
    // The subclass file does not contain the superclass at all, which is why
    // `removeFields` cannot reach it — it sees one compilation unit.
    const subclassFile = '''
import 'country.dart';

class Currency extends Country {
  Currency({super.id, super.language});

  factory Currency.fromJson(Map<String, dynamic> json) => Currency(
        id: json['id']?.toString(),
        language: json['language']?.toString(),
      );
}
''';

    String forward(Map<String, Set<String>> forwarded, [String? source]) =>
        ModelFieldFixer.removeSuperForwarding(
          content: source ?? subclassFile,
          path: '/tmp/currency.dart',
          forwarded: forwarded,
        ).newContent;

    test('a subclass in another file gives up its super parameter', () {
      final out = forward({
        'Country': {'language'}
      });
      expect(out, isNot(contains('super.language')));
      expect(out, isNot(contains('language:')));
      expect(out, contains('super.id'));
      expect(out, contains("id: json['id']"));
      expectParses(out, 'cross-file subclass');
    });

    test('a class extending something untouched is left alone', () {
      final out = forward({
        'SomethingElse': {'language'}
      });
      expect(out, subclassFile);
    });

    test('forwarding reaches a transitive subclass in the same file', () {
      const source = '''
import 'country.dart';

class Currency extends Country {
  Currency({super.id, super.language});
}

class LegacyCurrency extends Currency {
  LegacyCurrency({super.id, super.language});
}
''';
      final out = forward({
        'Country': {'language'}
      }, source);
      expect(out, isNot(contains('super.language')));
      expect(RegExp(r'super\.id').allMatches(out).length, 2);
      expectParses(out, 'transitive cross-file');
    });

    test('the superclass itself is never touched by this pass', () {
      // If the superclass happens to share the file, `removeFields` owns it —
      // this pass must not double-cut.
      const source = '''
class Country {
  String? language;
  Country({this.language});
}

class Currency extends Country {
  Currency({super.language});
}
''';
      final out = forward({
        'Country': {'language'}
      }, source);
      expect(out, contains('String? language;'));
      expect(out, contains('this.language'));
      expect(out, isNot(contains('super.language')));
    });
  });

  test('comment mode leaves the subclass parseable', () {
    final plan = ModelFieldFixer.removeFields(
      content: _aliasModel,
      path: '/tmp/subject.dart',
      className: 'Country',
      fieldNames: {'language'},
    );
    final out =
        ModelFieldFixer.applyEdits(_aliasModel, plan.edits, EditMode.comment);
    expectParses(out, 'commented subclass');
    // The forwarding parameter must be inside the comment, not left live
    // against a superclass that no longer declares it.
    expect(out, contains('/*super.language,*/'));
    expect(out, contains('/*this.language,*/'));
    expect(out, contains('super.id'));
  });
}
