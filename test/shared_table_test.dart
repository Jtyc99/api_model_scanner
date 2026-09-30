import 'dart:io';

import 'package:test/test.dart';

/// The two table editors draw from one script, kept as two copies because
/// they build in different languages. Every fix to one has to reach the
/// other, and a copy that quietly falls behind is how the two editors come
/// to disagree about what a click does.
void main() {
  String shared(String path) {
    final source = File(path).readAsStringSync();
    const open = '// <shared-table>';
    const close = '// </shared-table>';
    final start = source.indexOf(open);
    final end = source.indexOf(close);
    expect(start, isNonNegative, reason: '$path has no $open marker');
    expect(end, greaterThan(start), reason: '$path has no $close marker');
    return source.substring(start, end + close.length);
  }

  test('both editors run the same table script', () {
    final vscode = shared('editors/vscode/src/webview.ts');
    final intellij = shared(
      'editors/intellij/report/src/main/kotlin/com/jtycedgetech/amscan/Html.kt',
    );

    expect(intellij, vscode);
  });

  test('the script is safe to embed in both hosts unescaped', () {
    // `$` would be template interpolation in both Kotlin raw strings and
    // TypeScript template literals; a backtick ends the TypeScript one; and a
    // backslash is an escape in one and literal in the other.
    final script = shared('editors/vscode/src/webview.ts');

    expect(script, isNot(contains(r'$')));
    expect(script, isNot(contains('`')));
    expect(script, isNot(contains(r'\')));
  });
}
