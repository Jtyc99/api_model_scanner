import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:api_model_scanner/api_model_scanner.dart';
import 'package:test/test.dart';

/// A model whose `==` and `hashCode` join every field into an operator chain.
const _model = '''
class ReturnData {
  final int? status;
  final String? message;
  final String? errorMsg;
  final String? data;

  const ReturnData({this.status, this.message, this.errorMsg, this.data});

  @override
  bool operator ==(Object other) =>
      identical(other, this) ||
      other is ReturnData &&
          other.status == status &&
          other.message == message &&
          other.errorMsg == errorMsg &&
          other.data == data;

  @override
  int get hashCode =>
      status.hashCode ^
      message.hashCode ^
      errorMsg.hashCode ^
      data.hashCode;
}
''';

String apply(Set<String> fields, EditMode mode) {
  final plan = ModelFieldFixer.removeFields(
    content: _model,
    path: 'return_data.dart',
    className: 'ReturnData',
    fieldNames: fields,
  );
  return ModelFieldFixer.applyEdits(_model, plan.edits, mode);
}

void expectParses(String source, String reason) {
  final result = parseString(content: source, throwIfDiagnostics: false);
  final errors =
      result.errors.where((e) => e.severity.name.toLowerCase() == 'error').toList();
  expect(errors, isEmpty, reason: '$reason\n$source');
}

/// The body of `int get hashCode => …;`, whitespace collapsed.
String hashBody(String source) => source
    .split('int get hashCode')
    .last
    .split(';')
    .first
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceFirst('=>', '')
    .trim();

void main() {
  // Every subset, so no removal pattern can regress unnoticed.
  final fields = ['status', 'message', 'errorMsg', 'data'];
  final subsets = <Set<String>>[];
  for (var mask = 1; mask < 15; mask++) {
    subsets.add({
      for (var i = 0; i < 4; i++)
        if (mask & (1 << i) != 0) fields[i],
    });
  }

  for (final mode in EditMode.values) {
    group('${mode.name} mode', () {
      for (final subset in subsets) {
        test('removing ${subset.join(", ")} leaves valid code', () {
          expectParses(apply(subset, mode), 'subset: $subset');
        });
      }
    });
  }

  group('chain shape', () {
    test('a contiguous prefix does not leave a leading operator', () {
      // The original bug: cutting `status` and `message` independently ate
      // `status ^ message` but left the `^` belonging to `errorMsg`.
      final out = apply({'status', 'message'}, EditMode.delete);
      expect(hashBody(out), 'errorMsg.hashCode ^ data.hashCode');
    });

    test('a contiguous suffix does not leave a trailing operator', () {
      final out = apply({'errorMsg', 'data'}, EditMode.delete);
      expect(hashBody(out), 'status.hashCode ^ message.hashCode');
    });

    test('a contiguous middle run rejoins its neighbours', () {
      final out = apply({'message', 'errorMsg'}, EditMode.delete);
      expect(hashBody(out), 'status.hashCode ^ data.hashCode');
    });

    test('non-adjacent removals each take one operator', () {
      final out = apply({'status', 'errorMsg'}, EditMode.delete);
      expect(hashBody(out), 'message.hashCode ^ data.hashCode');
    });

    test('a single surviving operand needs no operator at all', () {
      final out = apply({'status', 'message', 'errorMsg'}, EditMode.delete);
      expect(hashBody(out), 'data.hashCode');
    });

    test('commenting a prefix swallows the joining operator', () {
      final out = apply({'status', 'message'}, EditMode.comment);
      // The chain spans several lines, so compare with whitespace collapsed.
      expect(
        out.replaceAll(RegExp(r'\s+'), ' '),
        contains('/*status.hashCode ^ message.hashCode ^*/'),
      );
      expectParses(out, 'commented prefix');
    });

    test('equality keeps `other is ReturnData` as the chain head', () {
      final out = apply({'status', 'message'}, EditMode.delete);
      expect(out, contains('other is ReturnData &&'));
      expect(out, contains('other.errorMsg == errorMsg'));
      expect(out.contains('other.status'), isFalse);
    });

    test('removing every operand does not leave an empty expression', () {
      // All four gone: the chain cannot simply vanish or `=> ;` results.
      final out = apply({'status', 'message', 'errorMsg', 'data'},
          EditMode.delete);
      expect(out.contains('=> ;'), isFalse);
      expect(out.contains('^ ^'), isFalse);
    });
  });
}
