import 'package:api_model_scanner/src/cli/editor.dart';
import 'package:api_model_scanner/src/cli/targets.dart';
import 'package:api_model_scanner/src/cli/gui.dart';
import 'package:test/test.dart';

void main() {
  group('naming an editor', () {
    test('every known command has a name someone would recognise', () {
      for (final command in knownEditors) {
        expect(editorDisplayName(command), isNot(command),
            reason: '$command is offered in a list but never translated');
      }
    });

    test('a label carries the name and the command it stands for', () {
      expect(editorLabel('code'), 'VS Code (code)');
      expect(editorLabel('code-insiders'), 'VS Code Insiders (code-insiders)');
    });

    test('an unrecognised command is left alone, not printed twice', () {
      expect(editorDisplayName('vscodium'), 'vscodium');
      expect(editorLabel('vscodium'), 'vscodium');
    });
  });

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

  group('what init offers to choose from', () {
    test('the installed ones, when any are installed', () {
      expect(editorChoices(const ['code', 'cursor']), ['code', 'cursor']);
    });

    test('every one it knows, when none are', () {
      // Still a choice worth making: the setting can be recorded now and the
      // editor installed later, and `gui install` says so if it cannot run.
      expect(editorChoices(const []), knownEditors);
    });
  });

  group('opening from an IDE terminal', () {
    test('a JetBrains terminal opens in Android Studio, not VS Code', () {
      final tried = editorCandidates(
        '/tmp/report.md',
        editor: 'code',
        environment: const {},
        host: HostIde.jetBrains,
        locateStudio: () =>
            '/Applications/Android Studio.app/Contents/MacOS/studio',
      );

      expect(tried.first,
          ['/Applications/Android Studio.app/Contents/MacOS/studio', '/tmp/report.md']);
    });

    test('no --reuse-window for it, which it does not understand', () {
      final first = editorCandidates(
        '/tmp/report.md',
        environment: const {},
        host: HostIde.jetBrains,
        locateStudio: () => '/bin/studio',
      ).first;

      expect(first, isNot(contains('--reuse-window')));
    });

    test('falls back to the configured editor when it cannot be found', () {
      final tried = editorCandidates(
        '/tmp/report.md',
        editor: 'code',
        environment: const {},
        host: HostIde.jetBrains,
        locateStudio: () => null,
      );

      expect(tried.first, ['code', '--reuse-window', '/tmp/report.md']);
    });

    test('a VS Code terminal is unaffected', () {
      final tried = editorCandidates(
        '/tmp/report.md',
        editor: 'code',
        environment: const {},
        host: HostIde.vsCode,
        locateStudio: () => '/bin/studio',
      );

      expect(tried.first, ['code', '--reuse-window', '/tmp/report.md']);
    });
  });
}
