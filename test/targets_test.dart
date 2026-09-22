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
}
