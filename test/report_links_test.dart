import 'package:api_model_scanner/src/cache/report.dart';
import 'package:api_model_scanner/src/cli/targets.dart';
import 'package:test/test.dart';

void main() {
  group('the link that lands on a line', () {
    test('from VS Code, it is a vscode:// link', () {
      final link = deepLink(
        text: 'VS Code',
        file: '/p/lib/a.dart',
        line: 12,
        host: HostIde.vsCode,
      );

      expect(link, '[VS Code](vscode://file/p/lib/a.dart:12:1)');
    });

    test('from a JetBrains IDE, it asks that IDE to open the file', () {
      // Its built-in server is what opens a file at a line; `vscode://` is
      // not a scheme it knows, so the row was simply dead there.
      final link = deepLink(
        text: 'Android Studio',
        file: '/p/lib/a.dart',
        line: 12,
        host: HostIde.jetBrains,
      );

      expect(link, contains('localhost:63342/api/file'));
      expect(link, contains('/p/lib/a.dart:12'));
      expect(link, startsWith('[Android Studio]('));
    });

    test('with no IDE to go on it stays with VS Code', () {
      expect(deepLink(text: 'VS Code', file: '/p/a.dart', line: 1, host: null),
          startsWith('[VS Code](vscode://'));
    });

    test('a path with spaces is encoded', () {
      for (final host in [HostIde.vsCode, HostIde.jetBrains]) {
        final link =
            deepLink(text: 'x', file: '/p/my dir/a.dart', line: 3, host: host);
        expect(link, isNot(contains('my dir')));
        expect(link, contains('my%20dir'));
      }
    });

    test('the label names the editor the link is for', () {
      expect(deepLinkLabel(HostIde.jetBrains), 'Android Studio');
      expect(deepLinkLabel(HostIde.vsCode), 'VS Code');
      expect(deepLinkLabel(null), 'VS Code');
    });
  });
}
