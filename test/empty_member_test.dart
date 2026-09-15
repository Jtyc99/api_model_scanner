import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:api_model_scanner/api_model_scanner.dart';
import 'package:test/test.dart';

String apply(String source, String className, Set<String> fields, EditMode mode) {
  final plan = ModelFieldFixer.removeFields(
    content: source,
    path: 'x.dart',
    className: className,
    fieldNames: fields,
  );
  return ModelFieldFixer.applyEdits(source, plan.edits, mode);
}

void expectParses(String source, String reason) {
  final result = parseString(content: source, throwIfDiagnostics: false);
  expect(
    result.errors.where((e) => e.severity.name.toLowerCase() == 'error'),
    isEmpty,
    reason: '$reason\n$source',
  );
}

/// A single-field model: its `hashCode` has exactly one term.
const _single = '''
class Tabs {
  final List<String>? tabs;
  const Tabs({this.tabs});
  @override
  int get hashCode => tabs.hashCode;
  @override
  bool operator ==(Object other) =>
      identical(other, this) || other is Tabs && other.tabs == tabs;
}
''';

/// A block-bodied hashCode, the other common shape.
const _blockBody = '''
class Tabs {
  final List<String>? tabs;
  const Tabs({this.tabs});
  @override
  int get hashCode {
    return tabs.hashCode;
  }
}
''';

void main() {
  for (final mode in EditMode.values) {
    group('${mode.name} mode', () {
      test('a hashCode with one term loses the whole getter', () {
        final out = apply(_single, 'Tabs', {'tabs'}, mode);
        expectParses(out, 'single-term hashCode');
        // The bug: `=> ;` or `=> /*tabs.hashCode*/;` are both syntax errors.
        expect(out.contains('=> ;'), isFalse);
        expect(
          RegExp(r'int get hashCode =>\s*/\*').hasMatch(out),
          isFalse,
          reason: 'the term was neutralised but the getter kept its body',
        );
      });

      test('a block-bodied hashCode is handled the same way', () {
        final out = apply(_blockBody, 'Tabs', {'tabs'}, mode);
        expectParses(out, 'block-bodied hashCode');
        expect(out.contains('return ;'), isFalse);
      });

      test('equality survives on its type check alone', () {
        final out = apply(_single, 'Tabs', {'tabs'}, mode);
        expectParses(out, 'equality');
        expect(out, contains('other is Tabs'));
      });
    });
  }

  test('delete removes the hashCode getter outright', () {
    final out = apply(_single, 'Tabs', {'tabs'}, EditMode.delete);
    expect(out.contains('hashCode'), isFalse);
    expect(out.contains('tabs'), isFalse);
  });

  test('comment keeps the getter visible but inert', () {
    final out = apply(_single, 'Tabs', {'tabs'}, EditMode.comment);
    expect(out, contains('/*@override'));
    expect(out, contains('int get hashCode => tabs.hashCode;*/'));
  });

  group('optional parameter groups', () {
    // Dart has no empty optional group: `Tabs({})` is `missing_identifier`.
    const withCopyWith = '''
class Tabs {
  final List<String>? tabs;
  const Tabs({this.tabs});
  Tabs copyWith({List<String>? tabs}) => Tabs(tabs: tabs ?? this.tabs);
}
''';

    test('emptying a named group removes the braces too', () {
      final out = apply(withCopyWith, 'Tabs', {'tabs'}, EditMode.delete);
      expectParses(out, 'empty named group');
      expect(out, contains('const Tabs();'));
      expect(out.contains('({})'), isFalse);
    });

    test('copyWith loses its braces as well', () {
      final out = apply(withCopyWith, 'Tabs', {'tabs'}, EditMode.delete);
      expect(out, contains('Tabs copyWith() => Tabs();'));
    });

    test('commenting takes the braces inside the comment', () {
      final out = apply(withCopyWith, 'Tabs', {'tabs'}, EditMode.comment);
      expectParses(out, 'commented named group');
      expect(out, contains('const Tabs(/*{this.tabs}*/);'));
    });

    test('a partially-emptied group keeps its braces', () {
      const two = '''
class Pair {
  final int? a;
  final int? b;
  const Pair({this.a, this.b});
}
''';
      final out = apply(two, 'Pair', {'a'}, EditMode.delete);
      expectParses(out, 'partial group');
      // Removing an inline item can leave a stray space; `dart format`, which
      // the CLI always runs, normalises it. Compare on structure instead.
      expect(out.replaceAll(' ', ''), contains('constPair({this.b});'));
    });

    test('required positional parameters survive an emptied group', () {
      const mixed = '''
class Mixed {
  final int? a;
  final int? b;
  const Mixed(this.a, {this.b});
}
''';
      final out = apply(mixed, 'Mixed', {'b'}, EditMode.delete);
      expectParses(out, 'mixed parameters');
      expect(out, contains('this.a'));
      expect(out.contains('{}'), isFalse);
    });
  });

  test('a multi-term hashCode still keeps its surviving terms', () {
    const two = '''
class Pair {
  final int? a;
  final int? b;
  const Pair({this.a, this.b});
  @override
  int get hashCode => a.hashCode ^ b.hashCode;
}
''';
    final out = apply(two, 'Pair', {'a'}, EditMode.delete);
    expectParses(out, 'two-term hashCode');
    expect(out, contains('int get hashCode => b.hashCode;'));
  });
}
