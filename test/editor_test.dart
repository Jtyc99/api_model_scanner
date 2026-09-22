import 'package:api_model_scanner/src/cli/editor.dart';
import 'package:api_model_scanner/src/cli/gui.dart';
import 'package:test/test.dart';

void main() {
  group('choosing an editor', () {
    test('reports only the ones installed, in preference order', () {
      final found = detectEditors(
        isAvailable: (command) =>
            command == 'windsurf' || command == 'code',
      );

      expect(found, ['code', 'windsurf']);
    });

    test('reports none when nothing is installed', () {
      expect(detectEditors(isAvailable: (_) => false), isEmpty);
    });

    test('knows the VS Code forks, not just VS Code', () {
      expect(detectEditors(isAvailable: (_) => true),
          containsAll(['code', 'cursor', 'windsurf']));
    });
  });

  group('opening the report', () {
    test('tries the chosen editor first, reusing its window', () {
      final tried = editorCandidates(
        '/tmp/report.md',
        editor: 'cursor',
        environment: const {},
      );

      expect(tried.first, ['cursor', '--reuse-window', '/tmp/report.md']);
    });

    test('falls back to \$EDITOR before the platform handler', () {
      final tried = editorCandidates(
        '/tmp/report.md',
        editor: 'cursor',
        environment: const {'EDITOR': 'vim'},
      );

      expect(tried[1], ['vim', '/tmp/report.md']);
    });

    test('ignores a blank \$EDITOR', () {
      final tried = editorCandidates(
        '/tmp/report.md',
        editor: 'code',
        environment: const {'EDITOR': '   '},
      );

      expect(tried.map((c) => c.first), isNot(contains('')));
    });
  });
}
