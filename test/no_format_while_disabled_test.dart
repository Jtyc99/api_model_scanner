import 'dart:io';

import 'package:api_model_scanner/api_model_scanner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Commenting code out must leave everything around it exactly as it was.
///
/// `dart format` rewrites the code *surrounding* a comment, and a separator it
/// removes is one `--undo` cannot put back. With the tall-style formatter,
/// `Ranking({a, b, /*c, d*/})` joins onto one line and loses the comma before
/// the comment; restoring `c, d` then yields `b c, d`, which does not parse.
void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('amscan_fmt'));
  tearDown(() => temp.deleteSync(recursive: true));

  /// Deliberately ragged, so any formatting run is obvious in the result.
  const source = '''
class Ranking {
  String?    date;
  String?    amount;

  Ranking({this.date,     this.amount});
}
''';

  Future<String> run(EditMode mode) async {
    final file = File(p.join(temp.path, 'ranking.dart'));
    file.writeAsStringSync(source);

    await applySelection(
      projectRoot: temp.path,
      fields: [
        CachedField(
          className: 'Ranking',
          fieldName: 'amount',
          filePath: file.path,
          line: 3,
        ),
      ],
      selection: const Selection(all: true),
      mode: mode,
      runFormat: true,
      verify: false,
      log: (_) {},
    );

    return file.readAsStringSync();
  }

  test('commenting out never reformats, even with --format on', () async {
    final out = await run(EditMode.comment);

    expect(out, contains('/*'), reason: 'the field should be commented out');
    // The ragged spacing survives: nothing but the comment markers moved.
    expect(
      out,
      contains('String?    date;'),
      reason: 'formatting would have collapsed this spacing',
    );
    // The separator lives inside the comment here, which is what makes the
    // undo safe — and the ragged spacing inside it proves nothing reformatted.
    expect(out, contains('/*,     this.amount*/'));
  });

  test('deleting still formats, where there is nothing left to restore',
      () async {
    final out = await run(EditMode.delete);

    expect(out, isNot(contains('/*')));
    expect(
      out,
      isNot(contains('String?    date;')),
      reason: 'delete mode is free to tidy up',
    );
  });
}
