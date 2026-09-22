import 'dart:io';

import 'package:api_model_scanner/src/cli/jetbrains.dart';
import 'package:api_model_scanner/src/cli/targets.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('amscan_tgt'));
  tearDown(() => temp.deleteSync(recursive: true));

  JetBrainsIde ide(String version, {bool withPlugin = false}) {
    final dir = Directory(p.join(temp.path, 'AndroidStudio$version'))
      ..createSync(recursive: true);
    if (withPlugin) {
      Directory(p.join(dir.path, 'plugins', intellijPluginName))
          .createSync(recursive: true);
    }
    return JetBrainsIde('Android Studio $version', dir.path);
  }

  group('where the report editor can go', () {
    test('VS Code comes before Android Studio', () {
      final targets = editorTargets(
        editors: const ['code', 'cursor'],
        ides: [ide('2025.3.4')],
      );

      expect(
        targets.map((t) => t.label),
        ['code', 'cursor', 'Android Studio 2025.3.4'],
      );
    });

    test('Android Studio alone is still a target', () {
      final targets = editorTargets(editors: const [], ides: [ide('2025.3.4')]);

      expect(targets, hasLength(1));
      expect(targets.single, isA<AndroidStudioTarget>());
    });

    test('nothing installed means nowhere to put it', () {
      expect(editorTargets(editors: const [], ides: const []), isEmpty);
    });

    test('the preferred target is VS Code when both are present', () {
      final targets = editorTargets(
        editors: const ['code'],
        ides: [ide('2025.3.4')],
      );

      expect(targets.first, isA<VsCodeTarget>());
      expect(targets.first.label, 'code');
    });

    test('a VS Code target names the command it drives', () {
      final target =
          editorTargets(editors: const ['cursor'], ides: const []).single;

      expect((target as VsCodeTarget).command, 'cursor');
    });

    test('an Android Studio target knows whether the plugin is there', () {
      final withIt = editorTargets(
        editors: const [],
        ides: [ide('2025.3.4', withPlugin: true)],
      ).single;
      final without =
          editorTargets(editors: const [], ides: [ide('2024.1')]).single;

      expect(withIt.installed, isTrue);
      expect(without.installed, isFalse);
    });

    test('only the newest Android Studio is offered', () {
      // Six stale config directories is normal; offering all of them would
      // bury the one that matters.
      final targets = editorTargets(
        editors: const [],
        ides: [ide('2024.1'), ide('2025.3.4'), ide('2025.1.1')],
      );

      expect(targets.map((t) => t.label), ['Android Studio 2025.3.4']);
    });
  });

  group('which one init should offer', () {
    test('the preferred editor, when it has not got it yet', () {
      final target = offerableTarget(editorTargets(
        editors: const [],
        ides: [ide('2025.3.4')],
      ));

      expect(target, isA<AndroidStudioTarget>());
    });

    test('skips one that already has it and offers the next', () {
      // The case that made init silent: the preferred editor is detected and
      // already set up, so there is nothing to offer there — but the next
      // one is sitting right behind it without the editor.
      final target = offerableTarget([
        AndroidStudioTarget(ide('2025.3.4', withPlugin: true)),
        AndroidStudioTarget(ide('2024.1')),
      ]);

      expect(target!.label, 'Android Studio 2024.1');
    });

    test('nothing to offer once every editor has it', () {
      expect(
        offerableTarget([
          AndroidStudioTarget(ide('2025.3.4', withPlugin: true)),
        ]),
        isNull,
      );
    });

    test('nothing to offer when there is no editor at all', () {
      expect(offerableTarget(const []), isNull);
    });
  });

  group('working out which IDE the terminal belongs to', () {
    test('VS Code says so', () {
      expect(
        detectHostIde(const {'TERM_PROGRAM': 'vscode'}),
        HostIde.vsCode,
      );
    });

    test('a JetBrains terminal says so', () {
      expect(
        detectHostIde(const {'TERMINAL_EMULATOR': 'JetBrains-JediTerm'}),
        HostIde.jetBrains,
      );
    });

    test('an IntelliJ shell that only sets its history file still counts', () {
      expect(
        detectHostIde(const {'__INTELLIJ_COMMAND_HISTFILE__': '/tmp/h'}),
        HostIde.jetBrains,
      );
    });

    test('a plain terminal belongs to nothing', () {
      expect(detectHostIde(const {'TERM': 'xterm-256color'}), isNull);
      expect(detectHostIde(const {}), isNull);
    });

    test('a JetBrains terminal wins over an inherited TERM_PROGRAM', () {
      // Opening a JetBrains terminal from a VS Code session leaves the older
      // variable behind; the innermost one is the one you are typing into.
      expect(
        detectHostIde(const {
          'TERM_PROGRAM': 'vscode',
          'TERMINAL_EMULATOR': 'JetBrains-JediTerm',
        }),
        HostIde.jetBrains,
      );
    });
  });

  group('ordering targets by the IDE you are in', () {
    test('a JetBrains terminal puts Android Studio first', () {
      final targets = editorTargets(
        editors: const ['code'],
        ides: [ide('2025.3.4')],
        host: HostIde.jetBrains,
      );

      expect(targets.first, isA<AndroidStudioTarget>());
    });

    test('a VS Code terminal puts VS Code first', () {
      final targets = editorTargets(
        editors: const ['code'],
        ides: [ide('2025.3.4')],
        host: HostIde.vsCode,
      );

      expect(targets.first, isA<VsCodeTarget>());
    });

    test('an unknown host keeps the default order', () {
      final targets = editorTargets(
        editors: const ['code'],
        ides: [ide('2025.3.4')],
      );

      expect(targets.first, isA<VsCodeTarget>());
    });

    test('ordering never drops a target', () {
      final targets = editorTargets(
        editors: const ['code', 'cursor'],
        ides: [ide('2025.3.4')],
        host: HostIde.jetBrains,
      );

      expect(targets.map((t) => t.label),
          containsAll(['code', 'cursor', 'Android Studio 2025.3.4']));
      expect(targets, hasLength(3));
    });
  });
}
